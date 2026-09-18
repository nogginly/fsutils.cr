require "http/client"
require "uri"
require "./host_policy"

module FsUtils
  module Web
    # Fetches one HTML page, bounded so that a caller cannot be handed more
    # than it asked to hold.
    #
    # ```
    # page = FsUtils::Web::Fetcher.new.fetch("https://example.com/docs")
    # page.url  # -> "https://example.com/docs/" after a redirect
    # page.html # -> "<!doctype html>..."
    # ```
    #
    # Redirects are followed here rather than by `HTTP::Client`, because each
    # hop is a new URL and has to face `HostPolicy` again: a permitted host
    # that answers with a redirect to `localhost` is the ordinary way an
    # allowlist is defeated.
    #
    # The byte cap counts what is read from the response body, not what
    # `Content-Length` claims. The header is absent under chunked encoding and
    # understates the truth under compression, which `HTTP::Client` inflates
    # on the way past -- so a two megabyte response can be a two gigabyte
    # read, and the only honest place to count is the read itself.
    class Fetcher
      DEFAULT_MAX_PAGE_BYTES = 8_388_608
      DEFAULT_MAX_REDIRECTS  =         5
      DEFAULT_USER_AGENT     = "fsutils"

      private CHUNK_BYTES = 16_384

      private HTML_TYPES = {"text/html", "application/xhtml+xml"}

      private REDIRECT_CODES = {301, 302, 303, 307, 308}

      private UTF8_NAMES = {"utf-8", "utf8", "us-ascii", "ascii"}

      # What was fetched, after any redirects.
      #
      # `url` is the address the content actually came from, which is what
      # relative links in `html` resolve against and what a caller should
      # report rather than the address it asked for.
      record Page,
        url : String,
        status : Int32,
        content_type : String?,
        html : String,
        bytes : Int64

      private record Redirect, location : String

      class Settings
        property max_page_bytes : Int64 = DEFAULT_MAX_PAGE_BYTES.to_i64
        property max_redirects = DEFAULT_MAX_REDIRECTS
        property timeout : Time::Span = 20.seconds
        property user_agent = DEFAULT_USER_AGENT
        property host_policy : HostPolicy::Settings = HostPolicy::Settings.new

        def initialize
        end

        def validate! : Nil
          raise ArgumentError.new("max_page_bytes must be positive") if max_page_bytes < 1
          raise ArgumentError.new("max_redirects must not be negative") if max_redirects < 0
          raise ArgumentError.new("timeout must be positive") unless timeout > Time::Span.zero
          raise ArgumentError.new("user_agent must not be blank") if user_agent.blank?
          host_policy.validate!
        end

        # Shallow, so `host_policy` is shared by reference: replace it, never
        # mutate it.
        def copy : self
          dup
        end
      end

      # Block form: the settings are yielded for amendment.
      def self.new(&)
        settings = Settings.new
        yield settings
        new(settings)
      end

      def initialize(@settings : Settings = Settings.new)
        @settings.validate!
        @policy = HostPolicy.new(@settings.host_policy)
      end

      # Raises `HostNotAllowedError`, `FetchFailedError`, `HttpError`,
      # `UnsupportedContentTypeError` or `TooLargeError`.
      def fetch(url : String) : Page
        uri = parse(url)
        hops = 0

        loop do
          @policy.check!(uri)
          result = hop(uri)
          return result if result.is_a?(Page)

          hops += 1
          raise too_many_redirects(url) if hops > @settings.max_redirects
          uri = redirect_to(uri, result.location)
        end
      end

      private def parse(url : String) : URI
        uri = URI.parse(url)
        scheme = uri.scheme.try(&.downcase)
        return uri if scheme == "http" || scheme == "https"
        raise HostNotAllowedError.new(
          "#{url} is not an http or https URL",
          "Send an http or https URL. Local files are read with read_text_file.")
      rescue ex : URI::Error
        raise FetchFailedError.new("#{url} is not a URL: #{ex.message}", "Send an absolute URL, such as https://example.com/page.")
      end

      private def redirect_to(uri : URI, location : String) : URI
        uri.resolve(location)
      rescue ex : URI::Error
        raise FetchFailedError.new(
          "#{uri} redirected to #{location}, which is not a URL: #{ex.message}",
          "Try a different page on this site.")
      end

      private def too_many_redirects(url : String) : FetchFailedError
        FetchFailedError.new(
          "#{url} redirected more than #{@settings.max_redirects} times",
          "Try the address the redirects were leading to, if it is known.")
      end

      private def hop(uri : URI) : Page | Redirect
        HTTP::Client.new(uri) do |client|
          configure(client)
          client.get(uri.request_target, headers: headers) do |response|
            location = response.headers["Location"]?
            if location && REDIRECT_CODES.includes?(response.status_code)
              Redirect.new(location)
            else
              page(uri, response)
            end
          end
        end
      rescue ex : IO::Error | Socket::Error
        raise FetchFailedError.new(
          "#{uri} could not be fetched: #{ex.message}",
          "Check the URL, or try again.")
      end

      private def configure(client : HTTP::Client) : Nil
        client.connect_timeout = @settings.timeout
        client.read_timeout = @settings.timeout
        client.write_timeout = @settings.timeout
      end

      private def headers : HTTP::Headers
        HTTP::Headers{
          "User-Agent" => @settings.user_agent,
          "Accept"     => "text/html,application/xhtml+xml",
        }
      end

      private def page(uri : URI, response : HTTP::Client::Response) : Page
        check_status(uri, response)
        check_type(uri, response)
        html, bytes = read_body(uri, response)
        Page.new(uri.to_s, response.status_code, response.content_type, html, bytes)
      end

      private def check_status(uri : URI, response : HTTP::Client::Response) : Nil
        return if response.status_code < 400
        raise HttpError.new(
          "#{uri} answered #{response.status_code} #{response.status_message}",
          "Check the URL. If it is right, the page may be gone or may require a sign-in this tool cannot provide.")
      end

      private def check_type(uri : URI, response : HTTP::Client::Response) : Nil
        type = response.content_type.try(&.downcase)
        return if type.nil? || HTML_TYPES.includes?(type)
        raise UnsupportedContentTypeError.new(
          "#{uri} answered #{type}, which this tool does not convert",
          "This tool reads HTML pages. Fetch an HTML page, or handle this content another way.")
      end

      # Reads in chunks so the cap is reached before the memory is.
      private def read_body(uri : URI, response : HTTP::Client::Response) : {String, Int64}
        io = response.body_io
        buffer = IO::Memory.new
        chunk = Bytes.new(CHUNK_BYTES)
        total = 0i64

        while (count = io.read(chunk)) > 0
          total += count
          raise too_large(uri) if total > @settings.max_page_bytes
          buffer.write(chunk[0, count])
        end

        {decode(buffer.to_slice, response.charset), total}
      end

      private def too_large(uri : URI) : TooLargeError
        TooLargeError.new(
          "#{uri} is larger than #{@settings.max_page_bytes} bytes",
          "Fetch a more specific page on this site, if one exists.")
      end

      private def decode(bytes : Bytes, charset : String?) : String
        name = charset.try(&.downcase)
        return String.new(bytes).scrub if name.nil? || UTF8_NAMES.includes?(name)

        io = IO::Memory.new(bytes)
        io.set_encoding(name, invalid: :skip)
        io.gets_to_end
      rescue ArgumentError
        String.new(bytes).scrub
      end
    end
  end
end
