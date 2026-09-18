module FsUtils
  # The headings of a Markdown document, each with the range of lines it
  # covers.
  #
  # ```
  # outline = FsUtils::Outline.of(markdown)
  # outline.headings.first.start_line # -> 1
  # outline.line_count                # -> 412
  # ```
  #
  # Line numbers are 1-based and count every line of the document, so a
  # heading's range is exactly what `Reader` wants as `offset` and `limit`:
  # a caller handed a large file and its outline can read one section of it
  # without reading the rest.
  #
  # A heading's range runs to the line before the next heading of the same
  # level or shallower, so a section contains its own subsections and the
  # ranges of nested headings overlap. Reading a section therefore gets a
  # whole section rather than the paragraph before its first subheading.
  #
  # Only ATX headings (`# Title`) are recognised, which is what
  # `Web::HtmlToMarkdown` emits. Text inside a fenced code block is never a
  # heading however it starts, or every shell comment in a documentation
  # page would become one.
  class Outline
    private ATX   = /^(\#{1,6})[ \t]+(.*?)[ \t]*\#*[ \t]*$/
    private FENCE = /^[ ]{0,3}(`{3,}|~{3,})/

    # A heading and the lines from it up to the next heading of the same
    # level or shallower.
    struct Heading
      getter level : Int32
      getter title : String
      getter start_line : Int32
      getter end_line : Int32

      def initialize(@level, @title, @start_line, @end_line)
      end

      # Lines covered, including the heading's own line.
      def lines : Int32
        @end_line - @start_line + 1
      end
    end

    getter headings : Array(Heading)
    getter line_count : Int32

    def self.of(markdown : String) : Outline
      new(markdown)
    end

    private def initialize(markdown : String)
      found = scan(markdown)
      @line_count = count_lines(markdown)
      @headings = close_ranges(found)
    end

    # Collects each heading's level, title and line, skipping fenced code.
    private def scan(markdown : String) : Array({Int32, String, Int32})
      found = [] of {Int32, String, Int32}
      fence = nil.as(String?)
      number = 0

      markdown.each_line do |line|
        number += 1
        if open = fence
          fence = nil if closes?(line, open)
          next
        end
        if marker = FENCE.match(line)
          fence = marker[1]
          next
        end
        next unless match = ATX.match(line)
        title = match[2].strip
        found << {match[1].size, title, number} unless title.empty?
      end

      found
    end

    # A fence closes on the same character, repeated at least as often.
    private def closes?(line : String, open : String) : Bool
      return false unless match = FENCE.match(line)
      marker = match[1]
      marker[0] == open[0] && marker.size >= open.size
    end

    # Each heading runs to the line before the next one at its level or
    # shallower, and the last one runs to the end of the document.
    private def close_ranges(found : Array({Int32, String, Int32})) : Array(Heading)
      found.map_with_index do |(level, title, start_line), index|
        following = found[(index + 1)..].find { |(other, _, _)| other <= level }
        end_line = following ? following[2] - 1 : @line_count
        Heading.new(level, title, start_line, end_line)
      end
    end

    private def count_lines(markdown : String) : Int32
      return 0 if markdown.empty?
      lines = markdown.count('\n')
      markdown.ends_with?('\n') ? lines : lines + 1
    end
  end
end
