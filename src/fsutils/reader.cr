module FsUtils
  # Reads a text file, in whole or by line range, bounded so that a caller
  # cannot accidentally ask for more than it can hold.
  #
  # ```
  # result = FsUtils::Reader.new("src/find.cr", offset: 12, limit: 2).read
  # result.content     # => "    12\tdef dispatch(call)\n    13\t  tool = ...\n"
  # result.total_lines # => 340
  # ```
  #
  # Like `Find` and `Grep`, this raises on caller error and knows nothing about
  # sandboxes or JSON. It also has no notion of whether a range was *asked for*
  # or defaulted — that is a judgement about intent, and it belongs to the tool
  # layer.
  class Reader
    DEFAULT_LIMIT     =       2_000
    DEFAULT_MAX_BYTES =     262_144
    MAX_FILE_BYTES    = 104_857_600

    # Long enough that a wrapped paragraph survives; short enough that one line
    # of minified JSON cannot fill the budget on its own.
    DEFAULT_MAX_LINE_LENGTH = 2_000

    # `cat -n` uses six columns, and matching it means the output is familiar
    # to anything that has ever read a terminal.
    NUMBER_WIDTH = 6

    enum TruncationReason
      LineLimit
      ByteBudget
      LongLines
    end

    # What was returned, and what was left behind.
    #
    # `first_line` and `last_line` are null for an empty file, or when `offset`
    # is past the end — both of which are answers rather than errors.
    record Result,
      content : String,
      first_line : Int32?,
      last_line : Int32?,
      total_lines : Int32,
      truncated : Bool,
      truncation_reason : TruncationReason?,
      lines_elided : Int32,
      long_lines : Int32 do
      def truncated? : Bool
        truncated
      end

      # True when the caller asked to start beyond the last line.
      def past_end? : Bool
        first_line.nil? && total_lines > 0
      end

      def empty_file? : Bool
        total_lines == 0
      end
    end

    def initialize(
      @path : String,
      @offset : Int32 = 1,
      @limit : Int32 = DEFAULT_LIMIT,
      @line_numbers : Bool = true,
      @max_bytes : Int32 = DEFAULT_MAX_BYTES,
      @max_line_length : Int32 = DEFAULT_MAX_LINE_LENGTH,
      @max_file_bytes : Int64 = MAX_FILE_BYTES.to_i64,
    )
      raise ArgumentError.new("offset must be 1 or greater") if @offset < 1
      raise ArgumentError.new("limit must be 1 or greater") if @limit < 1
      raise ArgumentError.new("path must not contain null bytes") if @path.includes?('\0')
    end

    def read : Result
      info = stat
      check_readable(info)

      ::File.open(@path, "r") do |file|
        if Text.binary?(file)
          raise FsUtils::Error.new(
            "#{@path} appears to be a binary file",
            "Binary content cannot be returned as text. Use a tool suited to \
its type, or search it with grep.")
        end
        scan(file)
      end
    end

    # ------------------------------------------------------------------ #

    private def stat : ::File::Info
      ::File.info(@path)
    rescue ::File::NotFoundError
      raise FsUtils::Error.new("#{@path} does not exist")
    rescue ::File::AccessDeniedError
      raise FsUtils::Error.new("#{@path} is not readable")
    end

    private def check_readable(info : ::File::Info) : Nil
      if info.directory?
        raise FsUtils::Error.new(
          "#{@path} is a directory, not a file",
          "List its contents instead, or name a file inside it.")
      end

      if info.size > @max_file_bytes
        raise FsUtils::Error.new(
          "#{@path} is #{info.size} bytes, over the #{@max_file_bytes} byte ceiling",
          "Search it with grep rather than reading it whole.")
      end
    end

    # Streams the whole file once: the requested window is rendered as it goes,
    # and every line is counted whether or not it is returned.
    #
    # Counting to the end costs a pass but makes `total_lines` exact, and an
    # exact total is what lets a caller judge how much it is missing without a
    # second call. An estimate would make the notice's "of 8,431" a guess in
    # the one field used to decide whether to read on.
    private def scan(file : ::File) : Result
      last_wanted = @offset.to_i64 + @limit - 1
      builder = String::Builder.new

      total = 0
      first_returned = nil.as(Int32?)
      last_returned = nil.as(Int32?)
      used = 0
      long_lines = 0
      budget_hit = false

      file.each_line(chomp: true) do |line|
        total += 1
        next if total < @offset
        next if total > last_wanted || budget_hit

        unless line.valid_encoding?
          raise FsUtils::Error.new(
            "#{@path} is not valid UTF-8 (line #{total})",
            "Only UTF-8 text can be returned. Convert the file, or treat it \
as binary.")
        end

        text, omitted = Text.clamp(line, @max_line_length)
        long_lines += 1 if omitted > 0
        rendered = render(total, text, omitted)

        if used + rendered.bytesize > @max_bytes && first_returned
          # At least one line is always returned, so a single enormous line
          # yields something rather than an empty success.
          budget_hit = true
          next
        end

        builder << rendered
        used += rendered.bytesize
        first_returned ||= total
        last_returned = total
      end

      build_result(builder, total, first_returned, last_returned, budget_hit, long_lines)
    end

    private def build_result(builder, total : Int32, first : Int32?, last : Int32?,
                             budget_hit : Bool, long_lines : Int32) : Result
      wanted_last = {total, @offset + @limit - 1}.min
      elided = last ? wanted_last - last : 0
      elided = 0 if elided < 0

      reason = if budget_hit
                 TruncationReason::ByteBudget
               elsif last && last < total
                 TruncationReason::LineLimit
               elsif long_lines > 0
                 TruncationReason::LongLines
               end

      Result.new(
        content: builder.to_s,
        first_line: first,
        last_line: last,
        total_lines: total,
        truncated: budget_hit || (last != nil && last != total),
        truncation_reason: reason,
        lines_elided: elided,
        long_lines: long_lines,
      )
    end

    private def render(number : Int32, text : String, omitted : Int32) : String
      String.build do |io|
        if @line_numbers
          io << number.to_s.rjust(NUMBER_WIDTH) << '\t'
        end
        io << text
        io << " [line truncated: #{omitted} of #{omitted + text.size} chars omitted]" if omitted > 0
        io << '\n'
      end
    end
  end
end
