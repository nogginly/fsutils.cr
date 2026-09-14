module FsUtils
  class Tools
    # A failure that belongs to no particular tool, so it carries the envelope
    # and nothing else.
    struct ErrorResponse
      include JSON::Serializable
      include Envelope

      def initialize(@error : ErrorInfo)
        @ok = false
      end
    end

    # A caller's arguments, checked against what the tool actually accepts.
    #
    # Every accessor either returns the typed value or raises `Rejected`,
    # which `Tools#call` turns into an error response. Nothing is coerced: a
    # `max_matches` of `"200"` is refused rather than read as 200, because a
    # model that learns the schema is worth more than one call saved.
    struct Arguments
      # An argument the model got wrong. Not a `FsUtils::Error`: those are
      # filesystem failures, and this never reaches the filesystem.
      class Rejected < Exception
        getter suggestion : String

        def initialize(@message : String?, @suggestion : String)
          super(@message)
        end
      end

      # The keys each tool accepts, read once from the published schemas so a
      # hand-kept list cannot drift from what the model was told.
      ACCEPTED = DEFINITIONS.to_h do |tool|
        {tool.name, JSON.parse(tool.schema)["properties"].as_h.keys}
      end

      @values : Hash(String, JSON::Any)

      # Raises `Rejected` if the arguments are not an object, or name anything
      # the tool does not accept.
      def initialize(@tool : String, arguments : JSON::Any)
        @values = object(arguments)
        reject_unknown
      end

      def string(key : String) : String
        string?(key) || raise missing(key, "string")
      end

      def string?(key : String) : String?
        value = @values[key]?
        return if value.nil? || value.raw.nil?
        value.as_s? || raise wrong_type(key, "a string", value)
      end

      def strings(key : String) : Array(String)
        value = @values[key]?
        return [] of String if value.nil? || value.raw.nil?
        array = value.as_a? || raise wrong_type(key, "an array of strings", value)
        array.map { |item| item.as_s? || raise wrong_type(key, "an array of strings", value) }
      end

      def int?(key : String) : Int32?
        value = @values[key]?
        return if value.nil? || value.raw.nil?
        (value.as_i64? || raise wrong_type(key, "an integer", value)).to_i32
      end

      def float?(key : String) : Float64?
        value = @values[key]?
        return if value.nil? || value.raw.nil?
        value.as_f? || raise wrong_type(key, "a number", value)
      end

      def bool?(key : String) : Bool?
        value = @values[key]?
        return if value.nil? || value.raw.nil?
        raw = value.raw
        raw.is_a?(Bool) ? raw : raise wrong_type(key, "true or false", value)
      end

      # The caller's value, or the tool's own default when absent. A nil
      # check rather than `||`, so an explicit `false` is honoured.
      def bool(key : String, default : Bool) : Bool
        value = bool?(key)
        value.nil? ? default : value
      end

      def int(key : String, default : Int32) : Int32
        value = int?(key)
        value.nil? ? default : value
      end

      def string(key : String, default : String) : String
        value = string?(key)
        value.nil? ? default : value
      end

      private def object(arguments : JSON::Any) : Hash(String, JSON::Any)
        return {} of String => JSON::Any if arguments.raw.nil?
        arguments.as_h? || raise Rejected.new(
          "arguments to #{@tool} must be a JSON object",
          "Send the arguments as an object of named parameters, or {} for none.")
      end

      private def reject_unknown : Nil
        accepted = ACCEPTED[@tool]
        unknown = @values.keys.reject { |key| accepted.includes?(key) }
        return if unknown.empty?

        raise Rejected.new(
          "#{@tool} does not accept #{unknown.join(", ")}",
          "Use only the parameters in the schema: #{accepted.join(", ")}.")
      end

      private def missing(key : String, kind : String) : Rejected
        Rejected.new("#{@tool} requires #{key}",
          "Call it again with #{key} set to a #{kind}.")
      end

      private def wrong_type(key : String, expected : String, value : JSON::Any) : Rejected
        Rejected.new("#{key} must be #{expected}, not #{value.to_json}",
          "Call it again with #{key} as #{expected}.")
      end
    end

    # Call a tool by the name it is published under.
    #
    # The five typed methods remain the API for Crystal callers; this is for a
    # host dispatching what a model asked for. The result is serialised JSON,
    # because that is what the model receives anyway and it saves needing a
    # common response type across five different result shapes.
    #
    # ```
    # tools.call("read_text_file", JSON.parse(%({"path": "src/main.cr"})))
    # ```
    #
    # Raises `ArgumentError` for a name that is not a tool. That is the one
    # failure here the model cannot fix: the host chose what to register, so
    # the host is who needs to know. Note that the name does arrive from a
    # model, which can invent one, so this wants a `rescue` rather than an
    # assumption that it cannot happen.
    #
    # Everything a model can fix comes back as an error response instead --
    # arguments that are not an object, unknown parameters, wrong types.
    def call(name : String, arguments : JSON::Any) : String
      raise ArgumentError.new("unknown tool: #{name}") unless Names::ALL.includes?(name)
      args = Arguments.new(name, arguments)

      case name
      when Names::FIND  then call_find(args)
      when Names::GREP  then call_grep(args)
      when Names::READ  then call_read(args)
      when Names::WRITE then call_write(args)
      else                   call_replace(args)
      end
    rescue ex : Arguments::Rejected
      ErrorResponse.new(ErrorInfo.new(
        ErrorCode::INVALID_ARGUMENT, ex.message || "invalid arguments",
        ex.suggestion)).to_json
    end

    private def call_find(args : Arguments) : String
      find(
        paths: args.strings("paths"),
        name: args.strings("name"),
        path: args.strings("path"),
        exclude: args.strings("exclude"),
        type: args.string?("type"),
        min_depth: args.int("min_depth", 0),
        max_depth: args.int?("max_depth"),
        max_matches: args.int?("max_matches"),
        include_hidden: args.bool?("include_hidden"),
        timeout_seconds: args.float?("timeout_seconds"),
      ).to_json
    end

    private def call_grep(args : Arguments) : String
      grep(
        pattern: args.string("pattern"),
        paths: args.strings("paths"),
        mode: args.string("mode", "lines"),
        ignore_case: args.bool("ignore_case", false),
        fixed_string: args.bool("fixed_string", false),
        types: args.strings("types"),
        include_globs: args.strings("include_globs"),
        exclude_globs: args.strings("exclude_globs"),
        max_matches: args.int?("max_matches"),
        max_matches_per_file: args.int?("max_matches_per_file"),
        max_depth: args.int?("max_depth"),
        include_hidden: args.bool?("include_hidden"),
        timeout_seconds: args.float?("timeout_seconds"),
      ).to_json
    end

    private def call_read(args : Arguments) : String
      read(
        path: args.string("path"),
        offset: args.int?("offset"),
        limit: args.int?("limit"),
        line_numbers: args.bool("line_numbers", true),
      ).to_json
    end

    private def call_write(args : Arguments) : String
      write(
        path: args.string("path"),
        content: args.string("content"),
        overwrite: args.bool("overwrite", false),
      ).to_json
    end

    private def call_replace(args : Arguments) : String
      text_replace(
        path: args.string("path"),
        old_string: args.string("old_string"),
        new_string: args.string("new_string"),
        replace_all: args.bool("replace_all", false),
      ).to_json
    end
  end
end
