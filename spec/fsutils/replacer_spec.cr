require "../spec_helper"

private def with_content(content : String, &)
  path = File.join(Dir.tempdir, "fsutils_replacer_#{Random.rand(UInt32)}.txt")
  begin
    File.write(path, content)
    yield path
  ensure
    File.delete?(path)
  end
end

private def sample : String
  <<-TEXT

  module Harness
    def dispatch(call)
      tool = registry[call.name]?
      raise UnknownTool.new(call.name) unless tool
      tool.run(call)
    end
  end

  TEXT
end

describe FsUtils::Replacer do
  describe "replacing" do
    it "replaces a unique occurrence and writes it" do
      with_content(sample) do |path|
        result = FsUtils::Replacer.new(path, "tool.run(call)", "tool.invoke(call)").replace

        result.replacements.should eq 1
        File.read(path).should contain "tool.invoke(call)"
        File.read(path).should_not contain "tool.run(call)"
      end
    end

    it "deletes text when new_string is empty" do
      with_content("keep\nremove me\nkeep\n") do |path|
        FsUtils::Replacer.new(path, "remove me\n", "").replace
        File.read(path).should eq "keep\nkeep\n"
      end
    end

    it "replaces every occurrence when asked" do
      with_content("a\nx\nb\nx\nc\nx\n") do |path|
        result = FsUtils::Replacer.new(path, "x", "y", replace_all: true).replace

        result.replacements.should eq 3
        File.read(path).should eq "a\ny\nb\ny\nc\ny\n"
      end
    end

    it "reports the net change in line count" do
      with_content("one\ntwo\nthree\n") do |path|
        result = FsUtils::Replacer.new(path, "two", "two\nand a half").replace
        result.lines_delta.should eq 1
      end
    end
  end

  describe "hunks" do
    it "returns the changed region with context either side" do
      with_content(sample) do |path|
        result = FsUtils::Replacer.new(path, "UnknownTool.new(call.name)",
          "UnknownTool.new(call.name, near: call.site)").replace

        hunk = result.hunks.first
        hunk.before.should contain "tool = registry"
        hunk.before.should contain "raise UnknownTool.new(call.name) unless tool"
        hunk.after.should contain "near: call.site"
        hunk.changed_lines.size.should eq 1
      end
    end

    it "slices after from what was written, not from a recomputation" do
      with_content(sample) do |path|
        result = FsUtils::Replacer.new(path, "dispatch", "handle").replace

        written = File.read(path)
        result.hunks.first.after.each_line do |line|
          written.should contain line
        end
      end
    end

    it "merges overlapping windows into one hunk" do
      with_content((1..20).map { |i| "line #{i}" }.join("\n") + "\n") do |path|
        # Two edits four lines apart: one hunk, not two with duplicated context.
        result = FsUtils::Replacer.new(path, "line", "row", replace_all: true).replace

        result.replacements.should eq 20
        result.hunks.size.should eq 1
        result.hunks.first.start_line.should eq 1
        result.hunks.first.end_line.should eq 20
      end
    end

    it "keeps separate hunks apart when they do not touch" do
      body = (1..40).map { |i| i == 5 || i == 30 ? "target" : "line #{i}" }.join("\n") + "\n"
      with_content(body) do |path|
        result = FsUtils::Replacer.new(path, "target", "hit", replace_all: true).replace

        result.hunks.size.should eq 2
        result.hunks.first.changed_lines.should eq [5]
        result.hunks.last.changed_lines.should eq [30]
      end
    end

    it "shifts after-numbers when the replacement changes line count" do
      body = (1..40).map { |i| i == 5 || i == 30 ? "target" : "line #{i}" }.join("\n") + "\n"
      with_content(body) do |path|
        result = FsUtils::Replacer.new(path, "target", "one\ntwo", replace_all: true).replace

        first = result.hunks.first
        first.start_line_after.should eq first.start_line
        first.end_line_after.should eq first.end_line + 1

        # The second hunk sits below one earlier edit, so it has moved.
        second = result.hunks.last
        second.start_line_after.should eq second.start_line + 1
        result.lines_delta.should eq 2
      end
    end

    it "caps the number of hunks and counts what it withheld" do
      body = (1..200).map { |i| i % 10 == 0 ? "target" : "line #{i}" }.join("\n") + "\n"
      with_content(body) do |path|
        result = FsUtils::Replacer.new(path, "target", "hit",
          replace_all: true, max_hunks: 5).replace

        result.replacements.should eq 20
        result.hunks.size.should eq 5
        result.hunks_omitted.should eq 15
      end
    end
  end

  describe "refusals" do
    it "refuses when nothing matches" do
      with_content(sample) do |path|
        expect_raises(FsUtils::NoMatchError) do
          FsUtils::Replacer.new(path, "nothing like this", "x").replace
        end
      end
    end

    it "diagnoses an indentation-only difference instead of guessing" do
      # The mismatch has to span a newline to bite: a single line indented
      # less than the file's is simply a substring of it, and matches.
      with_content("def thing\n    first\n    second\nend\n") do |path|
        error = expect_raises(FsUtils::NoMatchError) do
          FsUtils::Replacer.new(path, "  first\n  second", "x").replace
        end

        error.suggestion.not_nil!.should contain "indentation"
        error.suggestion.not_nil!.should contain "lines 2-3"
        # Nothing was written.
        File.read(path).should eq "def thing\n    first\n    second\nend\n"
      end
    end

    it "matches a single line indented less, because it is a substring" do
      with_content("def thing\n    indented\nend\n") do |path|
        FsUtils::Replacer.new(path, "  indented", "  changed").replace
        File.read(path).should eq "def thing\n    changed\nend\n"
      end
    end

    it "refuses several matches without replace_all, naming every line" do
      with_content("x\na\nx\nb\nx\n") do |path|
        error = expect_raises(FsUtils::NotUniqueError) do
          FsUtils::Replacer.new(path, "x", "y").replace
        end

        error.message.not_nil!.should contain "found 3"
        error.message.not_nil!.should contain "1, 3, 5"
        File.read(path).should eq "x\na\nx\nb\nx\n"
      end
    end

    it "refuses an empty old_string" do
      expect_raises(FsUtils::EmptyOldStringError) do
        FsUtils::Replacer.new("x", "", "new")
      end
    end

    it "refuses identical strings" do
      expect_raises(FsUtils::StringsIdenticalError) do
        FsUtils::Replacer.new("x", "same", "same")
      end
    end

    it "refuses a binary file" do
      with_content("text\u0000more\n") do |path|
        expect_raises(FsUtils::BinaryContentError) do
          FsUtils::Replacer.new(path, "text", "x").replace
        end
      end
    end

    it "refuses a missing file" do
      expect_raises(FsUtils::NotFoundError) do
        FsUtils::Replacer.new("/definitely/not/here", "a", "b").replace
      end
    end
  end

  describe "numbered prefixes" do
    it "strips them only when told the read was numbered" do
      with_content("alpha\nbeta\n") do |path|
        result = FsUtils::Replacer.new(path, "     1\talpha", "gamma",
          strip_numbered_prefixes: true).replace

        result.stripped_prefixes.should be_true
        File.read(path).should eq "gamma\nbeta\n"
      end
    end

    it "leaves a tab-separated file alone when the read was not numbered" do
      # Consulting recorded state rather than guessing from shape is the whole
      # point: this data file matches the same pattern.
      with_content("1\tvalue\n2\tother\n") do |path|
        result = FsUtils::Replacer.new(path, "1\tvalue", "1\tchanged").replace

        result.stripped_prefixes.should be_false
        File.read(path).should eq "1\tchanged\n2\tother\n"
      end
    end
  end
end
