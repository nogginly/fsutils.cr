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

    # The envelope for `fetch_as_markdown`.
    #
    # Either `content` is set, or `path` and the fields describing the file
    # are -- never both. Small pages come back whole; a large one is written
    # to the scratch area and described, so that fetching a reference page
    # cannot fill a small model's context on its own.
    struct MarkdownResponse
      include JSON::Serializable
      include Envelope

      # Where the content actually came from, after any redirects. Relative
      # links in the Markdown resolve against this, so it is the address to
      # report and the one to resolve against -- not the address asked for.
      getter url : String?
      getter status : Int32?
      getter title : String?
      # What the server said it sent. The response is Markdown either way;
      # this says whether that Markdown is a rendering of a page, the page
      # itself, or a data file inside a fence.
      getter content_type : String?
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
        @content_type = nil,
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

      def self.failure(code : String, message : String, suggestion : String? = nil) : MarkdownResponse
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    # Fetches an HTML page and returns it as Markdown.
    #
    # Three bounds apply in turn, and they are not substitutes for one
    # another: the fetcher stops reading past `max_page_bytes`, the converter
    # stops writing past `max_content_bytes`, and what survives is returned
    # inline only if it fits `max_output_bytes`. A page of boilerplate shrinks
    # under conversion and a page of dense tables grows.
    #
    # The network is not the sandbox, and this is the one tool that leaves the
    # machine. `Config::Fetch` carries its own guard: hosts are resolved and
    # every address checked, on the first request and on every redirect.
    def fetch_as_markdown(url : String) : MarkdownResponse
      started = Time.instant
      page = Web::Fetcher.new(@config.fetch.to_settings).fetch(url)
      kind = kind_of(page)
      markdown = markdown_for(page, kind)
      title = title_of(page, markdown, kind)
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

    private TAG_PREFIX = /\Ax-/

    private TAG_UNSAFE = /[^a-z0-9+_-]+/

    private RENDERED_TYPES = {"text/html", "application/xhtml+xml"}

    private MARKDOWN_SUFFIX = "/markdown"

    # Fence tags a model has seen against this content in the wild. Anything
    # absent falls back to the media subtype, which is usually already the
    # tag people use.
    private FENCE_TAGS = {
      "text/plain"                => "text",
      "text/csv"                  => "csv",
      "text/tab-separated-values" => "tsv",
      "text/css"                  => "css",
      "text/javascript"           => "javascript",
      "text/xml"                  => "xml",
      "application/xml"           => "xml",
      "application/json"          => "json",
      "application/yaml"          => "yaml",
      "text/yaml"                 => "yaml",
      "image/svg+xml"             => "svg",
    }

    # What has to happen to the body before it is Markdown.
    private enum Kind
      # HTML: prose extracted, shape discarded.
      Rendered
      # Already Markdown: used as it is.
      Served
      # Anything else textual: the bytes are the content, so they are put in
      # a fence rather than transformed. Markdown is the container; a model
      # has seen far more CSV inside ```csv than in any other presentation.
      Contained
    end

    private def kind_of(page : Web::Fetcher::Page) : Kind
      type = page.content_type.try(&.downcase)
      return Kind::Rendered if type.nil? || RENDERED_TYPES.includes?(type)
      type.ends_with?(MARKDOWN_SUFFIX) ? Kind::Served : Kind::Contained
    end

    # `max_content_bytes` bounds the payload in every case, or the limit
    # would mean one thing for a page converted here and nothing at all for
    # one the server had already prepared.
    private def markdown_for(page : Web::Fetcher::Page, kind : Kind) : Converted
      case kind
      in Kind::Rendered  then convert(page)
      in Kind::Served    then served(page)
      in Kind::Contained then contained(page)
      end
    end

    private def convert(page : Web::Fetcher::Page) : Converted
      output = IO::Memory.new
      result = Web::HtmlToMarkdown.translate(
        IO::Memory.new(page.body), output,
        base_url: page.url,
        max_bytes: @config.fetch.max_content_bytes)
      Converted.new(output.to_s, result.truncated?)
    end

    # Links are left alone: rewriting Markdown links needs a second parser,
    # and the front matter names the address they resolve against.
    private def served(page : Web::Fetcher::Page) : Converted
      text, truncated = Text.block_prefix(page.body, @config.fetch.max_content_bytes)
      Converted.new(text, truncated)
    end

    # Cut at a line rather than a blank line, because a blank line means
    # nothing in a CSV, and fence afterwards so the closing ticks are always
    # written -- a truncated document that ends inside an open fence is
    # exactly the case a reader cannot recover from.
    private def contained(page : Web::Fetcher::Page) : Converted
      payload, truncated = Text.line_prefix(page.body, @config.fetch.max_content_bytes)
      Converted.new(Text.fence(payload, fence_tag(page.content_type)), truncated)
    end

    private def fence_tag(content_type : String?) : String
      type = content_type.try(&.downcase) || "text/plain"
      return FENCE_TAGS[type] if FENCE_TAGS.has_key?(type)
      type.split('/').last.sub(TAG_PREFIX, "").gsub(TAG_UNSAFE, "")
    end

    # From <title> for HTML, read from the raw page because the converter
    # drops <head> with the rest of the chrome. A served Markdown document
    # has no head, so its first top-level heading stands in. Fenced content
    # has no title at all, and inventing one from a data file would be a
    # guess dressed as a fact.
    private def title_of(page : Web::Fetcher::Page, markdown : Converted, kind : Kind) : String?
      case kind
      in Kind::Served    then first_heading(markdown.text)
      in Kind::Contained then nil
      in Kind::Rendered
        match = TITLE_TAG.match(page.body)
        title = match ? HTML.unescape(match[1]).strip : ""
        title.empty? ? nil : title
      end
    end

    private def first_heading(text : String) : String?
      Outline.of(text).headings.find(&.level.==(1)).try(&.title)
    end

    private def front_matter(page : Web::Fetcher::Page, title : String?, truncated : Bool) : Hash(String, String)
      matter = {"source" => page.url}
      matter["title"] = title if title
      matter["content_type"] = page.content_type.to_s unless page.content_type.nil?
      matter["truncated"] = "true" if truncated
      matter
    end

    # One construction, with the branch in the values: a stored page fills
    # the file fields and an inlined one fills `content`, and neither fills
    # both.
    private def respond(page : Web::Fetcher::Page, title : String?,
                        markdown : Converted, held : Scratch::Inline | Scratch::Stored,
                        elapsed : Time::Span) : MarkdownResponse
      stored = held.is_a?(Scratch::Stored) ? held : nil

      MarkdownResponse.new(
        ok: true,
        url: page.url,
        status: page.status,
        title: title,
        content_type: page.content_type,
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

    private def fetch_failure(ex : Exception) : MarkdownResponse
      code = ex.is_a?(FsUtils::Error) ? ex.code : nil
      suggestion = ex.is_a?(FsUtils::Error) ? ex.suggestion : nil
      MarkdownResponse.failure(
        code || ErrorCode::FETCH_FAILED,
        ex.message || "the page could not be fetched",
        suggestion)
    end
  end
end
