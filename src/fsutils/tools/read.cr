module FsUtils
  class Tools
    # Where a line range starts and ends. Both null on an empty file.
    struct LineRange
      include JSON::Serializable
      getter first_line : Int32?
      getter last_line : Int32?

      def initialize(@first_line : Int32?, @last_line : Int32?)
      end
    end

    # The envelope for `read`. One file's content, not a list of results, which
    # is why it is not a `SearchResponse`.
    struct ReadResponse
      include JSON::Serializable
      include Envelope

      getter path : String?
      getter content : String?
      getter range : LineRange?
      # Always the file's full line count, so a caller can judge what it is
      # missing without a second call.
      getter total_lines : Int32?
      getter truncation_reason : String?
      # Lines inside the requested range that were not returned.
      getter lines_elided : Int32?
      # Lines returned but cut at the per-line ceiling. Counted separately
      # because a file whose lines are mostly cut is a file that wants grep.
      getter long_lines : Int32?

      def initialize(
        @ok,
        @path = nil,
        @content = nil,
        @range = nil,
        @total_lines = nil,
        @truncated = nil,
        @truncation_reason = nil,
        @lines_elided = nil,
        @long_lines = nil,
        @notice = nil,
        @error = nil,
      )
      end

      def self.failure(code : String, message : String, suggestion : String? = nil) : ReadResponse
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    # Returns the text of a file, whole or by line range.
    #
    # `offset` and `limit` are nilable rather than defaulted, because the
    # difference between "no range given" and "a range that happens to match
    # the defaults" decides how an overflow is answered — see below.
    def read(
      path : String,
      offset : Int32? = nil,
      limit : Int32? = nil,
      line_numbers : Bool = true,
    ) : ReadResponse
      resolved = @sandbox.resolve(path)
      unless ::File.exists?(resolved)
        return ReadResponse.failure(*not_found(resolved))
      end

      result = run_reader(resolved, offset, limit, line_numbers)

      # An implicit read that overflows returns the first page: the caller
      # asked for the file, and a page plus a notice is a helpful answer. An
      # explicit range that overflows is an error: the caller asked for
      # something precise and was wrong about its size, and quietly returning
      # less would let it proceed believing it saw the whole span.
      if explicit?(offset, limit) && result.truncation_reason.try(&.byte_budget?)
        return range_too_large(offset, limit, result)
      end

      success(resolved, result, offset)
    rescue ex : Sandbox::Escape | FsUtils::Error | ArgumentError
      read_failure(ex)
    end

    # A range is explicit when the caller supplied either bound. That, and not
    # the values, is what decides whether an overflow is a partial view or a
    # refusal.
    private def explicit?(offset : Int32?, limit : Int32?) : Bool
      !(offset.nil? && limit.nil?)
    end

    private def run_reader(resolved : String, offset : Int32?, limit : Int32?,
                           line_numbers : Bool) : Reader::Result
      Reader.new(
        resolved,
        offset: offset.nil? ? 1 : offset,
        limit: limit.nil? ? Reader::DEFAULT_LIMIT : limit,
        line_numbers: line_numbers,
      ).read
    end

    # `Sandbox::Escape` is a `FsUtils::Error`, so the order of these branches
    # is the specific-first order they are written in.
    private def read_failure(ex : Exception) : ReadResponse
      case ex
      when Sandbox::Escape
        ReadResponse.failure(
          ErrorCode::OUTSIDE_SANDBOX, message_of(ex, "path outside sandbox"),
          outside_sandbox_suggestion)
      when FsUtils::Error
        code, suggestion = classify_read(ex)
        ReadResponse.failure(code, message_of(ex, "cannot read file"), suggestion)
      else
        ReadResponse.failure(ErrorCode::INVALID_ARGUMENT, message_of(ex, "invalid argument"))
      end
    end

    private def message_of(ex : Exception, fallback : String) : String
      message = ex.message
      message.nil? ? fallback : message
    end

    private def success(resolved : String, result, offset : Int32?) : ReadResponse
      ReadResponse.new(
        ok: true,
        path: @sandbox.relative(resolved),
        content: result.content,
        range: LineRange.new(result.first_line, result.last_line),
        total_lines: result.total_lines,
        truncated: result.truncated? || nil,
        truncation_reason: result.truncation_reason.try(&.to_s.underscore),
        lines_elided: positive(result.lines_elided),
        long_lines: positive(result.long_lines),
        notice: read_notice(result, offset),
      )
    end

    private def range_too_large(offset : Int32?, limit : Int32?, result) : ReadResponse
      first = offset.nil? ? 1 : offset
      span = limit.nil? ? Reader::DEFAULT_LIMIT : limit
      last = first + span - 1
      ReadResponse.failure(
        ErrorCode::RANGE_TOO_LARGE,
        "lines #{first}–#{last} exceed the #{Reader::DEFAULT_MAX_BYTES} byte budget; #{result.lines_elided} lines were left",
        range_suggestion(result))
    end

    # Zero means "nothing to report", which is an absent field rather than a 0.
    private def positive(count : Int32) : Int32?
      count > 0 ? count : nil
    end

    private def classify_read(ex : FsUtils::Error) : {String, String?}
      message = ex.message.to_s
      code = case
             when message.includes?("binary")       then ErrorCode::BINARY_CONTENT
             when message.includes?("UTF-8")        then ErrorCode::NOT_UTF8
             when message.includes?("directory")    then ErrorCode::IS_DIRECTORY
             when message.includes?("ceiling")      then ErrorCode::TOO_LARGE
             when message.includes?("not readable") then ErrorCode::PERMISSION_DENIED
             else                                        ErrorCode::INVALID_ARGUMENT
             end
      {code, ex.suggestion}
    end

    private def range_suggestion(result) : String
      if result.long_lines > 0
        "One or more lines are very long. Search the file with grep rather \
than reading the range."
      else
        "Ask for fewer lines: try `limit: #{Math.max(result.last_line || 1, 1)}` or less."
      end
    end

    # An empty file and a missing one are different answers, and a model that
    # cannot tell them apart concludes the wrong thing about both.
    private def read_notice(result, offset : Int32?) : String?
      return "File exists but is empty." if result.empty_file?

      if result.past_end?
        return "Offset #{offset} is past the end; the file has #{result.total_lines} lines."
      end

      notes = [] of String

      if last = result.last_line
        if result.truncated? && last < result.total_lines
          notes << "PARTIAL view: lines #{result.first_line}–#{last} of #{result.total_lines}. Continue with `offset: #{last + 1}`."
        end
      end

      notes << "#{result.long_lines} lines were cut at the per-line limit; \
grep may serve better than reading this file." if result.long_lines > 0

      notes.empty? ? nil : notes.join(" ")
    end
  end
end
