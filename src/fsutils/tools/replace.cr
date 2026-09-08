module FsUtils
  class Tools
    struct HunkResult
      include JSON::Serializable
      getter start_line : Int32
      getter end_line : Int32
      getter start_line_after : Int32
      getter end_line_after : Int32
      # Lines that actually differ, in pre-edit numbering. Without it, a
      # fourteen-line merged hunk has to be diffed by eye to find the two lines
      # that moved.
      getter changed_lines : Array(Int32)
      getter before : String
      getter after : String

      def initialize(hunk : Replacer::Hunk)
        @start_line = hunk.start_line
        @end_line = hunk.end_line
        @start_line_after = hunk.start_line_after
        @end_line_after = hunk.end_line_after
        @changed_lines = hunk.changed_lines
        @before = hunk.before
        @after = hunk.after
      end
    end

    struct ReplaceResponse
      include JSON::Serializable
      include Envelope

      getter path : String?
      # A separate field from `hunks.size` precisely because merging means the
      # two are not the same number.
      getter replacements : Int32?
      # Net change in the file's line count. Any line numbers the caller holds
      # below the first match are stale by this much.
      getter lines_delta : Int32?
      getter hunks : Array(HunkResult)?
      getter hunks_omitted : Int32?

      def initialize(
        @ok,
        @path = nil,
        @replacements = nil,
        @lines_delta = nil,
        @hunks = nil,
        @hunks_omitted = nil,
        @notice = nil,
        @error = nil,
      )
      end

      def self.failure(code : String, message : String, suggestion : String? = nil) : ReplaceResponse
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    # Replaces occurrences of a literal string in a text file.
    #
    # `replace_all: false` asserts that `old_string` occurs exactly once, which
    # a caller can know from having read the region — unlike a count, which
    # asks it to tally the whole file, or an ordinal, which succeeds at the
    # wrong place when the tally is off.
    def text_replace(
      path : String,
      old_string : String,
      new_string : String,
      replace_all : Bool = false,
    ) : ReplaceResponse
      resolved = @sandbox.resolve(path)
      unless ::File.exists?(resolved)
        return ReplaceResponse.failure(*not_found(resolved))
      end

      result = Replacer.new(
        resolved,
        old_string,
        new_string,
        replace_all: replace_all,
      ).replace

      ReplaceResponse.new(
        ok: true,
        path: @sandbox.relative(resolved),
        replacements: result.replacements,
        lines_delta: result.lines_delta,
        hunks: result.hunks.map { |hunk| HunkResult.new(hunk) },
        hunks_omitted: positive(result.hunks_omitted),
        notice: replace_notice(result),
      )
    rescue ex : FsUtils::Error | ArgumentError
      replace_failure(ex)
    end

    private def replace_failure(ex : Exception) : ReplaceResponse
      case ex
      when FsUtils::Error
        ReplaceResponse.failure(code_of(ex), message_of(ex, "cannot replace"), ex.suggestion)
      else
        ReplaceResponse.failure(ErrorCode::INVALID_ARGUMENT, message_of(ex, "invalid argument"))
      end
    end

    private def replace_notice(result) : String?
      notes = [] of String

      if result.hunks_omitted > 0
        notes << "Showing #{result.hunks.size} of #{result.hunks.size + result.hunks_omitted} \
changed regions."
      end

      if result.lines_delta != 0
        notes << "The file's line count changed by #{result.lines_delta}; line numbers below \
the first change have moved."
      end

      notes.empty? ? nil : notes.join(" ")
    end
  end
end
