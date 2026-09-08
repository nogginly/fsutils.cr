module FsUtils
  # Replaces occurrences of a literal string in a text file.
  #
  # ```
  # result = FsUtils::Replacer.new(path, "old", "new").replace
  # result.replacements       # => 1
  # result.hunks.first.before # => the surrounding lines, as they were
  # ```
  #
  # Four rules shape everything here:
  #
  # 1. **Assert, do not select.** The caller states what it believes about the
  #    file; this verifies the belief or refuses. It never picks a match on the
  #    caller's behalf.
  # 2. **Fail loudly, never at the wrong place.** A silent edit at an
  #    unintended location is the worst outcome available, and worse than any
  #    refusal.
  # 3. **Show the work.** Every replacement comes back in context, so a wrong
  #    target is visible in the same turn rather than several turns later.
  # 4. **Match literally.** No regular expressions, no fuzzy inference. One
  #    documented diagnostic pass, which reports rather than corrects.
  class Replacer
    DEFAULT_CONTEXT_LINES =          3
    DEFAULT_MAX_HUNKS     =         20
    MAX_FILE_BYTES        = 10_485_760

    # A window of changed content, before and after.
    #
    # `before` is sliced from the file as read and `after` from the file as
    # written — neither is recomputed by re-applying the substitution to a
    # snippet. A recomputed `after` would make this report a re-derivation of
    # the edit rather than evidence of it: should the splice and the
    # recomputation ever diverge, the result would assert the right thing
    # happened while the wrong thing sat on disk.
    record Hunk,
      start_line : Int32,
      end_line : Int32,
      start_line_after : Int32,
      end_line_after : Int32,
      changed_lines : Array(Int32),
      before : String,
      after : String

    record Result,
      replacements : Int32,
      lines_delta : Int32,
      hunks : Array(Hunk),
      hunks_omitted : Int32,
      stripped_prefixes : Bool

    def initialize(
      @path : String,
      @old_string : String,
      @new_string : String,
      @replace_all : Bool = false,
      @context_lines : Int32 = DEFAULT_CONTEXT_LINES,
      @max_hunks : Int32 = DEFAULT_MAX_HUNKS,
      @max_file_bytes : Int64 = MAX_FILE_BYTES.to_i64,
      # Set by the tool layer from a read log. Never inferred from the shape of
      # `old_string`: a tab-separated data file read without numbering would
      # satisfy the same pattern and must not be stripped.
      @strip_numbered_prefixes : Bool = false,
    )
      raise ArgumentError.new("path must not contain null bytes") if @path.includes?('\0')

      if @old_string.empty?
        raise EmptyOldStringError.new(
          "old_string must not be empty",
          "To create or replace a whole file, write it instead.")
      end

      if @old_string == @new_string
        raise StringsIdenticalError.new("old_string and new_string are identical")
      end
    end

    def replace : Result
      original = load
      needle, stripped = resolve_needle
      offsets = find_all(original, needle)

      refuse_no_match(original, needle) if offsets.empty?
      refuse_not_unique(original, offsets) if offsets.size > 1 && !@replace_all

      targets = @replace_all ? offsets : offsets[0, 1]
      updated = splice(original, targets, needle)

      Writer.new(@path, updated).write

      build_result(original, updated, targets, needle, stripped)
    end

    # ------------------------------------------------------------------ #
    # Reading
    # ------------------------------------------------------------------ #

    private def load : String
      info = ::File.info(@path)

      if info.directory?
        raise IsDirectoryError.new("#{@path} is a directory, not a file")
      end

      if info.size > @max_file_bytes
        raise TooLargeError.new(
          "#{@path} is #{info.size} bytes, over the #{@max_file_bytes} byte ceiling")
      end

      content = ::File.read(@path)

      if Text.binary?(content.to_slice[0, {content.bytesize, Text::SNIFF_BYTES}.min])
        raise BinaryContentError.new("#{@path} appears to be a binary file")
      end

      content
    rescue ::File::NotFoundError
      raise NotFoundError.new("#{@path} does not exist")
    rescue ::File::AccessDeniedError
      raise PermissionDeniedError.new("#{@path} is not readable")
    end

    # The predictable failure of a numbered read is that the caller lifts
    # `old_string` from what it saw, `    42\t` prefixes included.
    private def resolve_needle : {String, Bool}
      return {@old_string, false} unless @strip_numbered_prefixes
      return {@old_string, false} unless numbered?(@old_string)
      {strip_prefixes(@old_string), true}
    end

    private def numbered?(text : String) : Bool
      lines = text.split('\n')
      lines = lines[0, lines.size - 1] if lines.size > 1 && lines.last.empty?
      return false if lines.empty?
      lines.all?(&.matches?(/\A\s*\d+\t/))
    end

    private def strip_prefixes(text : String) : String
      text.split('\n').map(&.sub(/\A\s*\d+\t/, "")).join('\n')
    end

    # ------------------------------------------------------------------ #
    # Matching
    # ------------------------------------------------------------------ #

    private def find_all(haystack : String, needle : String) : Array(Int32)
      offsets = [] of Int32
      from = 0
      while index = haystack.byte_index(needle, from)
        offsets << index
        from = index + needle.bytesize
      end
      offsets
    end

    # Diagnosis, not accommodation.
    #
    # Exact-match failure — not ambiguity — is the dominant way string editors
    # fail, and the usual response is to soften matching until something hits.
    # That produces a tool whose behaviour is a function of more than its
    # inputs, and whose mistakes are invisible by construction. So: find where
    # it *would* have matched, change nothing, and say exactly what differs.
    # The caller retries once, correctly.
    private def refuse_no_match(original : String, needle : String) : NoReturn
      hint = indentation_hint(original, needle)
      raise NoMatchError.new(
        "old_string was not found in #{@path}",
        hint || "Check the text against the file exactly, including whitespace. \
Reading the region first is usually quicker than guessing.")
    end

    private def indentation_hint(original : String, needle : String) : String?
      flat_file = flatten(original)
      flat_needle = flatten(needle)
      return if flat_needle.empty?

      index = flat_file.byte_index(flat_needle)
      return unless index

      first_line = flat_file[0, index].count('\n') + 1
      last_line = first_line + flat_needle.count('\n')

      "No exact match, but the text appears at lines #{first_line}-#{last_line} \
with different leading indentation. Retry using the file's own indentation."
    end

    private def flatten(text : String) : String
      text.split('\n').map(&.lstrip).join('\n')
    end

    private def refuse_not_unique(original : String, offsets : Array(Int32)) : NoReturn
      lines = offsets.map { |offset| line_at(original, offset) }
      raise NotUniqueError.new(
        "expected one occurrence, found #{offsets.size} (lines #{lines.join(", ")})",
        "Extend old_string with surrounding context to isolate one, or set \
replace_all: true to change every occurrence.")
    end

    # ------------------------------------------------------------------ #
    # Splicing
    # ------------------------------------------------------------------ #

    private def splice(original : String, offsets : Array(Int32), needle : String) : String
      String.build do |io|
        cursor = 0
        offsets.each do |offset|
          io.write(original.to_slice[cursor, offset - cursor])
          io << @new_string
          cursor = offset + needle.bytesize
        end
        io.write(original.to_slice[cursor, original.bytesize - cursor])
      end
    end

    private def line_at(text : String, byte_offset : Int32) : Int32
      String.new(text.to_slice[0, byte_offset]).count('\n') + 1
    end

    # ------------------------------------------------------------------ #
    # Hunks
    # ------------------------------------------------------------------ #

    private def build_result(original : String, updated : String, offsets : Array(Int32),
                             needle : String, stripped : Bool) : Result
      before_lines = split_lines(original)
      after_lines = split_lines(updated)

      per_match_delta = @new_string.count('\n') - needle.count('\n')
      spans = match_spans(original, offsets, needle)
      windows = merge(spans.map { |span| expand(span, before_lines.size) })

      hunks = cut(windows, spans, before_lines, after_lines, per_match_delta)
      omitted = hunks.size > @max_hunks ? hunks.size - @max_hunks : 0

      Result.new(
        replacements: offsets.size,
        lines_delta: after_lines.size - before_lines.size,
        hunks: omitted > 0 ? hunks[0, @max_hunks] : hunks,
        hunks_omitted: omitted,
        stripped_prefixes: stripped,
      )
    end

    private def split_lines(text : String) : Array(String)
      lines = text.split('\n')
      lines = lines[0, lines.size - 1] if lines.size > 1 && lines.last.empty?
      lines
    end

    # The line range each match occupies, in the pre-edit numbering.
    private def match_spans(original : String, offsets : Array(Int32),
                            needle : String) : Array({Int32, Int32})
      offsets.map do |offset|
        first = line_at(original, offset)
        {first, first + needle.count('\n')}
      end
    end

    private def expand(span : {Int32, Int32}, total : Int32) : {Int32, Int32}
      first = {span[0] - @context_lines, 1}.max
      last = {span[1] + @context_lines, total}.min
      {first, last}
    end

    # Two edits four lines apart produce one hunk of seven lines, not two
    # hunks with duplicated context.
    private def merge(windows : Array({Int32, Int32})) : Array({Int32, Int32})
      merged = [] of {Int32, Int32}
      windows.each do |window|
        last = merged.last?
        if last && window[0] <= last[1] + 1
          merged[-1] = {last[0], {last[1], window[1]}.max}
        else
          merged << window
        end
      end
      merged
    end

    private def cut(windows, spans, before_lines, after_lines, per_match_delta) : Array(Hunk)
      windows.map do |window|
        first, last = window
        inside = spans.select { |span| span[0] >= first && span[0] <= last }
        preceding = spans.count { |span| span[0] < first }

        offset_before = preceding * per_match_delta
        offset_within = inside.size * per_match_delta

        changed = inside.flat_map { |span| (span[0]..span[1]).to_a }

        Hunk.new(
          start_line: first,
          end_line: last,
          start_line_after: first + offset_before,
          end_line_after: last + offset_before + offset_within,
          changed_lines: changed.uniq,
          before: slice(before_lines, first, last),
          after: slice(after_lines, first + offset_before, last + offset_before + offset_within),
        )
      end
    end

    private def slice(lines : Array(String), first : Int32, last : Int32) : String
      first = {first, 1}.max
      last = {last, lines.size}.min
      return "" if first > last
      lines[(first - 1)..(last - 1)].join('\n') + "\n"
    end
  end
end
