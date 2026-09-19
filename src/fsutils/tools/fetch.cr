require "html"

module FsUtils
  class Tools
    # One heading of a stored page, and the lines it covers.
    #
    # `start_line` and `end_line` are what `read_text_file` takes as `offset`
    # and `limit`: the index is into a tool the caller already has, rather
    # than a new capability to learn.
    struct Heading
      include JSON::Serializable

      getter level : Int32
      getter title : String
      getter start_line : Int32
      getter end_line : Int32

      def initialize(@level, @title, @start_line, @end_line)
      end
    end

    # The envelope for `fetch`.
    #
    # Either `content` is set, or `path` and the fields describing the file
    # are -- never both. Small pages come back whole; a large one is written
    # to the scratch area and described, so that fetching a reference page
    # cannot fill a small model's context on its own.
    struct FetchResponse
      include JSON::Serializable
      include Envelope

      # Where the content actually came from, after any redirects. Relative
      # links in the Markdown resolve against this, so it is the address to
      # report and the one to resolve against -- not the address asked for.
      getter url : String?
      getter status : Int32?
      getter title : String?
      # Bytes of Markdown, not bytes off the wire.
      getter bytes : Int64?

      getter content : String?

      getter path : String?
      getter lines : Int32?
      getter excerpt : String?
      getter toc : Array(Heading)?

      getter elapsed_ms : Float64?

      def initialize(
        @ok,
        @url = nil,
        @status = nil,
        @title = nil,
        @bytes = nil,
        @content = nil,
        @path = nil,
        @lines = nil,
        @excerpt = nil,
        @toc = nil,
        @elapsed_ms = nil,
        @truncated = nil,
        @notice = nil,
        @error = nil,
      )
      end

      def self.failure(code : String, message : String, suggestion : String? = nil) : FetchResponse
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    # Fetches an HTML page and returns it as Markdown.
    #
    # Three bounds apply in turn, and they are not substitutes for one
    # another: the fetcher stops reading past `max_page_bytes`, the converter
    # stops writing past `max_markdown_bytes`, and what survives is returned
    # inline only if it fits `max_output_bytes`. A page of boilerplate shrinks
    # under conversion and a page of dense tables grows.
    #
    # The network is not the sandbox, and this is the one tool that leaves the
    # machine. `Config::Fetch` carries its own guard: hosts are resolved and
    # every address checked, on the first request and on every redirect.
    def fetch_as_markdown(url : String) : FetchResponse
      started = Time.instant
      page = Web::Fetcher.new(@config.fetch.to_settings).fetch(url)
      markdown = markdown_for(page)
      title = title_of(page, markdown)
      held = @scratch.hold(page.url, markdown.text, front_matter(page, title, markdown.truncated?))

      respond(page, title, markdown, held, Time.instant - started)
    rescue ex : FsUtils::Error | ArgumentError
      fetch_failure(ex)
    end

    # What the conversion produced, and whether it was cut short.
    private record Converted, text : String, truncated : Bool do
      def truncated? : Bool
        truncated
      end
    end

    private TITLE_TAG = /<title[^>]*>(.*?)<\/title>/im

    # A server that answered the Accept header with Markdown has already done
    # the work; the bound still applies, or `max_markdown_bytes` would mean
    # one thing for a page we converted and nothing at all for a page we did
    # not. Links are left as they are: rewriting Markdown links is a second
    # parser, and the front matter names the address they resolve against.
    private def markdown_for(page : Web::Fetcher::Page) : Converted
      return convert(page) unless page.markdown?
      text, truncated = Text.block_prefix(page.body, @config.fetch.max_markdown_bytes)
      Converted.new(text, truncated)
    end

    private def convert(page : Web::Fetcher::Page) : Converted
      output = IO::Memory.new
      result = Web::HtmlToMarkdown.translate(
        IO::Memory.new(page.body), output,
        base_url: page.url,
        max_bytes: @config.fetch.max_markdown_bytes)
      Converted.new(output.to_s, result.truncated?)
    end

    # From <title> for HTML, read from the raw page because the converter
    # drops <head> with the rest of the chrome. A Markdown document has no
    # head, so its first top-level heading stands in.
    private def title_of(page : Web::Fetcher::Page, markdown : Converted) : String?
      return first_heading(markdown.text) if page.markdown?
      return unless match = TITLE_TAG.match(page.body)
      title = HTML.unescape(match[1]).strip
      title.empty? ? nil : title
    end

    private def first_heading(text : String) : String?
      Outline.of(text).headings.find(&.level.==(1)).try(&.title)
    end

    private def front_matter(page : Web::Fetcher::Page, title : String?, truncated : Bool) : Hash(String, String)
      matter = {"source" => page.url}
      matter["title"] = title if title
      matter["truncated"] = "true" if truncated
      matter
    end

    # One construction, with the branch in the values: a stored page fills
    # the file fields and an inlined one fills `content`, and neither fills
    # both.
    private def respond(page : Web::Fetcher::Page, title : String?,
                        markdown : Converted, held : Scratch::Inline | Scratch::Stored,
                        elapsed : Time::Span) : FetchResponse
      stored = held.is_a?(Scratch::Stored) ? held : nil

      FetchResponse.new(
        ok: true,
        url: page.url,
        status: page.status,
        title: title,
        bytes: markdown.text.bytesize.to_i64,
        content: held.is_a?(Scratch::Inline) ? held.content : nil,
        path: stored.try(&.path),
        lines: stored.try(&.lines),
        excerpt: stored.try(&.excerpt),
        toc: stored ? stored.headings.map { |heading| to_heading(heading) } : nil,
        truncated: markdown.truncated? || nil,
        notice: fetch_notice(markdown, held),
        elapsed_ms: fetch_elapsed_ms(elapsed))
    end

    private def to_heading(heading : Outline::Heading) : Heading
      Heading.new(heading.level, heading.title, heading.start_line, heading.end_line)
    end

    private def fetch_elapsed_ms(elapsed : Time::Span) : Float64?
      return if @config.reproducible?
      elapsed.total_milliseconds.round(1)
    end

    private def fetch_notice(markdown : Converted, held : Scratch::Inline | Scratch::Stored) : String?
      notices = [] of String
      notices << "The page was longer than the limit; the Markdown stops at a block boundary and the rest was not converted." if markdown.truncated?
      if held.is_a?(Scratch::Stored) && held.headings_truncated
        notices << "The page has more headings than fit; toc lists the top-level ones only."
      end
      notices.empty? ? nil : notices.join(" ")
    end

    private def fetch_failure(ex : Exception) : FetchResponse
      code = ex.is_a?(FsUtils::Error) ? ex.code : nil
      suggestion = ex.is_a?(FsUtils::Error) ? ex.suggestion : nil
      FetchResponse.failure(
        code || ErrorCode::FETCH_FAILED,
        ex.message || "the page could not be fetched",
        suggestion)
    end
  end
end
