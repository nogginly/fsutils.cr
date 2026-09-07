module FsUtils
  class Tools
    # The envelope for `write`.
    struct WriteResponse
      include JSON::Serializable
      include Envelope

      getter path : String?
      # True for a new file, false for a replacement. The most useful field
      # here: a false where the caller expected true is a stale belief, and it
      # surfaces without a verification read.
      getter created : Bool?
      getter bytes_written : Int64?
      getter lines : Int32?
      # Directories actually created, in order. A non-empty value the caller
      # did not expect is usually a mistyped path.
      getter parents_created : Array(String)?

      def initialize(
        @ok,
        @path = nil,
        @created = nil,
        @bytes_written = nil,
        @lines = nil,
        @parents_created = nil,
        @notice = nil,
        @error = nil,
      )
      end

      def self.failure(code : String, message : String, suggestion : String? = nil) : WriteResponse
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    # Creates a text file, or replaces one in full.
    #
    # The guard is asymmetric on purpose: `overwrite: false` never destroys
    # anything, in any state. A call that sometimes refuses is recoverable —
    # the error names what is missing and the caller fixes it in one step. A
    # call that sometimes destroys is not, because nothing tells the caller
    # which world it was in until the content is gone.
    #
    # NOTE: without a session read log this guard is weaker than the scope
    # document describes. It catches "you did not know this file was here"; it
    # cannot catch "you knew, but you have not looked", which needs a record of
    # what the caller has read.
    def write(
      path : String,
      content : String,
      overwrite : Bool = false,
    ) : WriteResponse
      resolved = @sandbox.resolve(path)

      if ::File.exists?(resolved) && !overwrite
        return file_exists(resolved)
      end

      previous = ::File.exists?(resolved) ? count_lines(resolved) : nil
      result = Writer.new(resolved, content).write

      WriteResponse.new(
        ok: true,
        path: @sandbox.relative(resolved),
        created: result.created,
        bytes_written: result.bytes_written,
        lines: result.lines,
        parents_created: result.parents_created.map { |dir| @sandbox.relative(dir) },
        notice: write_notice(result, previous),
      )
    rescue ex : FsUtils::Error | ArgumentError
      write_failure(ex)
    end

    private def file_exists(resolved : String) : WriteResponse
      lines = count_lines(resolved)
      WriteResponse.failure(
        ErrorCode::FILE_EXISTS,
        "#{@sandbox.relative(resolved)} already exists (#{lines} lines)",
        "Set `overwrite: true` to replace it, or use text_replace for a partial change.")
    end

    private def write_failure(ex : Exception) : WriteResponse
      case ex
      when FsUtils::Error
        WriteResponse.failure(code_of(ex), message_of(ex, "cannot write file"), ex.suggestion)
      else
        WriteResponse.failure(ErrorCode::INVALID_ARGUMENT, message_of(ex, "invalid argument"))
      end
    end

    private def write_notice(result, previous : Int32?) : String?
      notes = [] of String

      if previous && previous > result.lines * 2 && previous > 10
        notes << "Replaced #{previous} lines with #{result.lines}. \
The previous content is not recoverable."
      end

      if result.parents_created.size > 1
        notes << "Created #{result.parents_created.size} directory levels. \
If that was not intended, the path is probably mistyped."
      end

      notes.empty? ? nil : notes.join(" ")
    end

    private def count_lines(path : String) : Int32
      count = 0
      ::File.open(path, "r") { |file| file.each_line { count += 1 } }
      count
    rescue
      0
    end
  end
end
