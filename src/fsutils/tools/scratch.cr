require "digest/sha256"

module FsUtils
  class Tools
    # Holds output too large to return inline, as a file inside the sandbox.
    #
    # ```
    # held = scratch.hold("https://example.com/docs", markdown, {"source" => "https://example.com/docs"})
    # case held
    # in Scratch::Inline then held.content
    # in Scratch::Stored then held.path
    # end
    # ```
    #
    # Nothing here is specific to a web page. Any tool whose result may not
    # fit a response wants the same three things: a file the caller can read
    # back with `read_text_file`, an index of where things are in it, and
    # enough of the opening to judge whether it is worth reading.
    #
    # The directory lives *inside* the sandbox root, because a model that
    # cannot read the file back has been given a path it can do nothing with.
    # It is hidden, and `find` and `grep` skip it, so a tool's own spilled
    # output never turns up in that tool's own later searches.
    #
    # A stored file opens with YAML front matter carrying its provenance. The
    # response knows where content came from, but the file outlives the
    # response: a caller reading it back three turns later has only the file.
    # There is no timestamp in it, deliberately -- a clock would make the same
    # fetch produce different bytes and break `reproducible` on the next tool
    # to spill.
    class Scratch
      DEFAULT_DIR = ".agent-scratch"

      # Enough to tell a report from a reference page, short enough that a
      # model can skim several.
      DEFAULT_EXCERPT_CHARS = 400

      # A long reference page has hundreds of headings, and a table of
      # contents that fills the response defeats the point of spilling.
      DEFAULT_MAX_HEADINGS = 200

      private SLUG_UNSAFE = /[^a-z0-9]+/

      private MAX_SLUG_CHARS = 60

      # Long enough that two pages on one site do not collide, short enough
      # to read. Derived from the key, never from a clock or a counter, so a
      # re-fetch overwrites its own previous file.
      private KEY_DIGEST_CHARS = 8

      # Content small enough to return in the response itself.
      record Inline, content : String

      # Content written to the scratch directory.
      #
      # `path` is relative to the sandbox root, ready to hand back to a model
      # and to pass to `read_text_file`. Heading line numbers count the front
      # matter, because they are only useful if they address the file as it
      # actually is.
      record Stored,
        path : String,
        bytes : Int64,
        lines : Int32,
        excerpt : String,
        headings : Array(Outline::Heading),
        headings_truncated : Bool

      class Settings
        property dir : String = DEFAULT_DIR
        property max_inline_bytes : Int32 = DEFAULT_MAX_OUTPUT_BYTES
        property excerpt_chars : Int32 = DEFAULT_EXCERPT_CHARS
        property max_headings : Int32 = DEFAULT_MAX_HEADINGS

        def initialize
        end

        def validate! : Nil
          raise ArgumentError.new("scratch dir must not be blank") if dir.blank?
          raise ArgumentError.new("scratch dir must be a relative path inside the workspace") if dir.starts_with?(::File::SEPARATOR)
          raise ArgumentError.new("max_inline_bytes must be positive") if max_inline_bytes < 1
          raise ArgumentError.new("excerpt_chars must be positive") if excerpt_chars < 1
          raise ArgumentError.new("max_headings must be positive") if max_headings < 1
        end

        def copy : self
          dup
        end
      end

      getter settings : Settings

      def initialize(@sandbox : Sandbox, @settings : Settings = Settings.new)
        @settings.validate!
      end

      # The directory's name, for adding to a search's `skip_dirs`.
      def dir : String
        @settings.dir
      end

      # Returns the content inline when it fits, and otherwise writes it.
      #
      # `key` names the content rather than the file: the same key writes the
      # same file, so re-fetching a page replaces its previous copy instead of
      # littering.
      def hold(key : String, content : String, front_matter : Hash(String, String)) : Inline | Stored
        return Inline.new(content) if content.bytesize <= @settings.max_inline_bytes
        store(key, content, front_matter)
      end

      # Writes whatever it is given, whatever its size.
      def store(key : String, content : String, front_matter : Hash(String, String)) : Stored
        document = preamble(front_matter) + content
        resolved = write(filename(key), document)
        outline = Outline.of(document)
        headings, truncated = cap(outline.headings)

        Stored.new(
          path: @sandbox.relative(resolved),
          bytes: document.bytesize.to_i64,
          lines: outline.line_count,
          excerpt: excerpt(content),
          headings: headings,
          headings_truncated: truncated)
      end

      private def write(name : String, document : String) : String
        directory = @sandbox.resolve(@settings.dir)
        ::Dir.mkdir_p(directory)
        resolved = @sandbox.resolve(::File.join(@settings.dir, name))
        ::File.write(resolved, document)
        resolved
      rescue ex : ::File::Error | IO::Error
        raise WriteFailedError.new(
          "the scratch file could not be written: #{ex.message}",
          "The workspace may be read-only or full.")
      end

      # Values are rendered as JSON, which is also a valid YAML double-quoted
      # scalar, so a title holding a colon or a quote needs no escaper here.
      private def preamble(front_matter : Hash(String, String)) : String
        return "" if front_matter.empty?
        String.build do |io|
          io << "---\n"
          front_matter.each { |key, value| io << key << ": " << value.to_json << '\n' }
          io << "---\n\n"
        end
      end

      private def filename(key : String) : String
        "#{slug(key)}-#{digest(key)}.md"
      end

      private def slug(key : String) : String
        text = key.downcase.gsub(SLUG_UNSAFE, "-").strip('-')
        return "page" if text.empty?
        text.size > MAX_SLUG_CHARS ? text[0, MAX_SLUG_CHARS].strip('-') : text
      end

      private def digest(key : String) : String
        Digest::SHA256.hexdigest(key)[0, KEY_DIGEST_CHARS]
      end

      private def excerpt(content : String) : String
        text = content.lstrip
        return text if text.size <= @settings.excerpt_chars
        text[0, @settings.excerpt_chars].rstrip
      end

      # Deep headings go first, since the shape of a document is carried by
      # its top two levels. Only if that is still too many is the list cut.
      private def cap(headings : Array(Outline::Heading)) : {Array(Outline::Heading), Bool}
        return {headings, false} if headings.size <= @settings.max_headings

        shallow = headings.select { |heading| heading.level <= 2 }
        return {shallow, true} if shallow.size <= @settings.max_headings
        {shallow.first(@settings.max_headings), true}
      end
    end
  end
end
