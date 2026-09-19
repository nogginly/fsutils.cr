require "../spec_helper"

# Spelled out rather than heredoc'd, because every assertion below is a
# line number.
private DOC = [
  "# Title",           # 1
  "",                  # 2
  "Opening prose.",    # 3
  "",                  # 4
  "## First",          # 5
  "",                  # 6
  "Text under first.", # 7
  "",                  # 8
  "### Nested",        # 9
  "",                  # 10
  "Deeper text.",      # 11
  "",                  # 12
  "## Second",         # 13
  "",                  # 14
  "Last line.",        # 15
].join('\n') + "\n"

describe FsUtils::Outline do
  it "finds every ATX heading with its level and title" do
    outline = FsUtils::Outline.of(DOC)

    outline.headings.map(&.title).should eq ["Title", "First", "Nested", "Second"]
    outline.headings.map(&.level).should eq [1, 2, 3, 2]
  end

  it "runs a section to the line before the next heading of its level or shallower" do
    outline = FsUtils::Outline.of(DOC)
    first = outline.headings[1]
    nested = outline.headings[2]

    first.start_line.should eq 5
    first.end_line.should eq 12
    nested.start_line.should eq 9
    nested.end_line.should eq 12
  end

  it "runs the last heading to the end of the document" do
    outline = FsUtils::Outline.of(DOC)

    outline.line_count.should eq 15
    outline.headings.last.end_line.should eq 15
  end

  # A section contains its subsections, so one read of a heading's range
  # returns a whole section rather than its preamble.
  it "covers a subsection within its parent's range" do
    outline = FsUtils::Outline.of(DOC)
    title = outline.headings.first
    nested = outline.headings[2]

    title.start_line.should eq 1
    title.end_line.should eq 15
    (title.start_line <= nested.start_line && nested.end_line <= title.end_line).should be_true
  end

  # Otherwise every shell comment in a documentation page is a heading.
  it "ignores headings inside a fenced code block" do
    outline = FsUtils::Outline.of(<<-MD)
      # Real

      ```sh
      # not a heading
      ```

      ## Also real
      MD

    outline.headings.map(&.title).should eq ["Real", "Also real"]
  end

  it "closes a fence only on the same marker, repeated at least as often" do
    outline = FsUtils::Outline.of(<<-MD)
      ````
      ```
      # still fenced
      ````

      # free
      MD

    outline.headings.map(&.title).should eq ["free"]
  end

  it "reports lines covered" do
    FsUtils::Outline.of(DOC).headings[3].lines.should eq 3
  end

  it "reads a closing sequence of hashes as decoration" do
    FsUtils::Outline.of("### Title ###\n").headings.first.title.should eq "Title"
  end

  it "skips a heading marker with no title" do
    FsUtils::Outline.of("#\n\n## Real\n").headings.map(&.title).should eq ["Real"]
  end

  it "answers an empty outline for text with no headings" do
    outline = FsUtils::Outline.of("just prose\nover two lines\n")

    outline.headings.should be_empty
    outline.line_count.should eq 2
  end

  it "counts a final line with no newline" do
    FsUtils::Outline.of("one\ntwo").line_count.should eq 2
  end
end
