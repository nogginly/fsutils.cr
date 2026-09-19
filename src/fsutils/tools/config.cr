require "json"
require "yaml"

module FsUtils
  class Tools
    # What a host allows its tools to do.
    #
    # Serialisable so it can be a section of a larger document:
    #
    # ```
    # config = FsUtils::Tools::Config.from_yaml(File.read("agent.yml"))
    # tools = FsUtils::Tools.new("/srv/project", config)
    # ```
    #
    # Every field has a default and every section is optional, so a document
    # naming one limit leaves the rest standing. Sections mirror the tools
    # rather than the helpers: `find` and `grep` repeat the traversal bounds
    # because a host may well want a shallower grep than find.
    #
    # This is the tool layer's type. Helpers take their own `Settings`, which
    # carry `Time::Span` and know nothing of YAML; a section converts.
    class Config
      include YAML::Serializable
      include JSON::Serializable

      # Bounds `find`.
      class Find
        include YAML::Serializable
        include JSON::Serializable

        property max_matches : Int32 = 200
        property max_matches_per_dir : Int32 = 100
        property max_entries_scanned : Int32 = 100_000
        property max_depth : Int32 = 32
        property timeout_seconds : Float64 = 10.0
        property? follow_symlinks : Bool = false
        property? include_hidden : Bool = false
        property skip_dirs : Array(String) = Walk::DEFAULT_SKIP_DIRS

        def initialize
        end

        def to_settings : FsUtils::Find::Settings
          settings = FsUtils::Find::Settings.new
          settings.max_matches = max_matches
          settings.max_matches_per_dir = max_matches_per_dir
          settings.max_entries_scanned = max_entries_scanned
          settings.max_depth = max_depth
          settings.timeout = timeout_seconds.seconds
          settings.follow_symlinks = follow_symlinks?
          settings.include_hidden = include_hidden?
          settings.skip_dirs = skip_dirs
          settings
        end
      end

      # Bounds `grep`.
      class Grep
        include YAML::Serializable
        include JSON::Serializable

        property max_matches : Int32 = 200
        property max_matches_per_file : Int32 = 20
        property max_matches_per_dir : Int32 = 100
        property max_entries_scanned : Int32 = 20_000
        property max_depth : Int32 = 25
        property max_file_bytes : Int64 = 5_000_000_i64
        property max_line_length : Int32 = 1_000
        property timeout_seconds : Float64 = 10.0
        property? follow_symlinks : Bool = false
        property? include_hidden : Bool = false
        property skip_dirs : Array(String) = Walk::DEFAULT_SKIP_DIRS

        def initialize
        end

        def to_settings : FsUtils::Grep::Settings
          settings = FsUtils::Grep::Settings.new
          settings.max_matches = max_matches
          settings.max_matches_per_file = max_matches_per_file
          settings.max_matches_per_dir = max_matches_per_dir
          settings.max_entries_scanned = max_entries_scanned
          settings.max_depth = max_depth
          settings.max_file_bytes = max_file_bytes
          settings.max_line_length = max_line_length
          settings.timeout = timeout_seconds.seconds
          settings.follow_symlinks = follow_symlinks?
          settings.include_hidden = include_hidden?
          settings.skip_dirs = skip_dirs
          settings
        end
      end

      # Bounds `read`. `default_limit` is the line window used when the caller
      # names neither `offset` nor `limit`; the other three are ceilings the
      # caller cannot raise.
      class Read
        include YAML::Serializable
        include JSON::Serializable

        property default_limit : Int32 = Reader::DEFAULT_LIMIT
        property max_bytes : Int32 = Reader::DEFAULT_MAX_BYTES
        property max_line_length : Int32 = Reader::DEFAULT_MAX_LINE_LENGTH
        property max_file_bytes : Int64 = Reader::MAX_FILE_BYTES.to_i64

        def initialize
        end

        def to_settings : Reader::Settings
          settings = Reader::Settings.new
          settings.max_bytes = max_bytes
          settings.max_line_length = max_line_length
          settings.max_file_bytes = max_file_bytes
          settings
        end
      end

      # Bounds `write`.
      class Write
        include YAML::Serializable
        include JSON::Serializable

        property max_content_bytes : Int64 = Writer::MAX_CONTENT_BYTES.to_i64

        def initialize
        end

        def to_settings : Writer::Settings
          settings = Writer::Settings.new
          settings.max_content_bytes = max_content_bytes
          settings
        end
      end

      # Bounds `text_replace`.
      class Replace
        include YAML::Serializable
        include JSON::Serializable

        property context_lines : Int32 = Replacer::DEFAULT_CONTEXT_LINES
        property max_hunks : Int32 = Replacer::DEFAULT_MAX_HUNKS
        property max_file_bytes : Int64 = Replacer::MAX_FILE_BYTES.to_i64

        def initialize
        end

        def to_settings : Replacer::Settings
          settings = Replacer::Settings.new
          settings.context_lines = context_lines
          settings.max_hunks = max_hunks
          settings.max_file_bytes = max_file_bytes
          settings
        end
      end

      # Bounds `fetch_as_markdown`, and guards where it may go.
      #
      # `allowed_hosts` is nil when there is no allowlist. An empty array is
      # an allowlist naming nothing, which permits nothing -- a list means
      # exactly what it contains. `denied_hosts` is never nil for the same
      # reason read the other way: an empty denylist forbids nothing.
      class Fetch
        include YAML::Serializable
        include JSON::Serializable

        property max_page_bytes : Int64 = FsUtils::Web::Fetcher::DEFAULT_MAX_PAGE_BYTES.to_i64
        property max_content_bytes : Int64 = 4_194_304_i64
        property timeout_seconds : Float64 = 20.0
        property max_redirects : Int32 = FsUtils::Web::Fetcher::DEFAULT_MAX_REDIRECTS
        property user_agent : String = FsUtils::Web::Fetcher::DEFAULT_USER_AGENT
        property? allow_private_hosts : Bool = false
        property allowed_hosts : Array(String)? = nil
        property denied_hosts : Array(String) = [] of String
        # Nil leaves the fetcher's own default, which is any text type plus
        # JSON, XML and SVG. A list replaces it outright.
        property accepted_types : Array(String)? = nil

        def initialize
        end

        def to_settings : FsUtils::Web::Fetcher::Settings
          settings = FsUtils::Web::Fetcher::Settings.new
          settings.max_page_bytes = max_page_bytes
          settings.max_redirects = max_redirects
          settings.timeout = timeout_seconds.seconds
          settings.user_agent = user_agent
          settings.host_policy = host_policy
          if types = accepted_types
            settings.accepted_types = types
          end
          settings
        end

        private def host_policy : FsUtils::Web::HostPolicy::Settings
          policy = FsUtils::Web::HostPolicy::Settings.new
          policy.allowed_hosts = allowed_hosts
          policy.denied_hosts = denied_hosts
          policy.allow_private_hosts = allow_private_hosts?
          policy
        end
      end

      # Where output too large to return inline is kept.
      #
      # `dir` is relative to the workspace root and hidden by default, and
      # `find` and `grep` skip it, so a tool's own spilled output does not
      # turn up in that tool's own later searches.
      class Scratch
        include YAML::Serializable
        include JSON::Serializable

        property dir : String = FsUtils::Tools::Scratch::DEFAULT_DIR
        property excerpt_chars : Int32 = FsUtils::Tools::Scratch::DEFAULT_EXCERPT_CHARS
        property max_headings : Int32 = FsUtils::Tools::Scratch::DEFAULT_MAX_HEADINGS

        def initialize
        end

        # The threshold between inlining and spilling is `max_output_bytes`
        # rather than a number of its own: "how much may a response be" is
        # one question, already answered once, and a second answer would let
        # a page spill at a size a search would inline.
        def to_settings(max_inline_bytes : Int32) : FsUtils::Tools::Scratch::Settings
          settings = FsUtils::Tools::Scratch::Settings.new
          settings.dir = dir
          settings.max_inline_bytes = max_inline_bytes
          settings.excerpt_chars = excerpt_chars
          settings.max_headings = max_headings
          settings
        end
      end

      # Serialised bytes beyond this are dropped from any response.
      property max_output_bytes : Int32 = DEFAULT_MAX_OUTPUT_BYTES

      # Omit fields that report *when* or *where* a call ran, leaving only
      # what is derived from the tree's contents and paths. Two identical
      # calls then return byte-identical JSON, on any machine, from any
      # checkout -- which is what makes a response usable as a recorded
      # fixture, as a cache entry, or as one half of a run-to-run comparison.
      #
      # The fields removed are the contract, and the list will grow:
      #
      # - `summary.elapsed_ms` on `find_files` and `search_file_contents`
      # - `modified` on each `find_files` result
      #
      # Removed, not zeroed. An `elapsed_ms` of 0.0 is a number a model may
      # reason about; an absent field is the honest form.
      #
      # NOTE: this covers fields that are volatile by *construction*. A time
      # budget is volatile by *measurement*: an identical call may stop early
      # on a slower machine and return less. A response whose `stop_reason`
      # is `timeout` did different work, and no flag can make that otherwise
      # -- assert that it does not happen. Bounding a walk by work rather
      # than by clock avoids it: `max_matches`, `max_depth` and
      # `max_entries_scanned` truncate identically everywhere.
      property? reproducible : Bool = false

      property find : Find = Find.new
      property grep : Grep = Grep.new
      property read : Read = Read.new
      property write : Write = Write.new
      property replace : Replace = Replace.new
      property scratch : Scratch = Scratch.new
      property fetch : Fetch = Fetch.new

      def initialize
      end

      # Raises `ArgumentError` on a limit that cannot be honoured. Called by
      # `Tools#initialize`: a host reads a startup failure, where a tool call
      # must answer with JSON instead.
      def validate! : Nil
        raise ArgumentError.new("max_output_bytes must be positive") if max_output_bytes < 1
        raise ArgumentError.new("read.default_limit must be positive") if read.default_limit < 1
        find.to_settings.validate!
        grep.to_settings.validate!
        read.to_settings.validate!
        write.to_settings.validate!
        replace.to_settings.validate!
        scratch.to_settings(max_output_bytes).validate!
        fetch.to_settings.validate!
        raise ArgumentError.new("fetch.max_content_bytes must be positive") if fetch.max_content_bytes < 1
      end
    end
  end
end
