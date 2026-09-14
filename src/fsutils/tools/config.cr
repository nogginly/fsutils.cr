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

      # Serialised bytes beyond this are dropped from any response.
      property max_output_bytes : Int32 = DEFAULT_MAX_OUTPUT_BYTES

      property find : Find = Find.new
      property grep : Grep = Grep.new
      property read : Read = Read.new
      property write : Write = Write.new
      property replace : Replace = Replace.new

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
      end
    end
  end
end
