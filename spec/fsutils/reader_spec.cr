require "../spec_helper"

private def with_file(content : String, &)
  path = File.join(Dir.tempdir, "fsutils_reader_#{Random.rand(UInt32)}.txt")
  begin
    File.write(path, content)
    yield path
  ensure
    File.delete?(path)
  end
end

private def numbered_lines : String
  (1..10).map { |i| "line #{i}" }.join("\n") + "\n"
end

describe FsUtils::Reader do
  describe "whole file" do
    it "numbers lines with their true file numbers" do
      with_file(numbered_lines) do |path|
        result = FsUtils::Reader.new(path).read

        result.content.lines.first.should eq "     1\tline 1"
        result.total_lines.should eq 10
        result.first_line.should eq 1
        result.last_line.should eq 10
        result.truncated?.should be_false
        result.truncation_reason.should be_nil
      end
    end

    it "returns raw lines when numbering is off" do
      with_file(numbered_lines) do |path|
        result = FsUtils::Reader.new(path, line_numbers: false).read
        result.content.should eq numbered_lines
      end
    end
  end

  describe "ranges" do
    it "opens at the requested offset, numbered from the file" do
      with_file(numbered_lines) do |path|
        result = FsUtils::Reader.new(path, offset: 4, limit: 2).read

        result.content.lines.map(&.strip).should eq ["4\tline 4", "5\tline 5"]
        result.first_line.should eq 4
        result.last_line.should eq 5
        result.total_lines.should eq 10
      end
    end

    it "reports the full line count even when returning a slice" do
      with_file(numbered_lines) do |path|
        FsUtils::Reader.new(path, limit: 2).read.total_lines.should eq 10
      end
    end

    it "marks a line-limited read as truncated" do
      with_file(numbered_lines) do |path|
        result = FsUtils::Reader.new(path, limit: 3).read

        result.truncated?.should be_true
        result.truncation_reason.should eq FsUtils::Reader::TruncationReason::LineLimit
      end
    end

    it "is not truncated when the range reaches the end" do
      with_file(numbered_lines) do |path|
        FsUtils::Reader.new(path, offset: 8, limit: 50).read.truncated?.should be_false
      end
    end
  end

  describe "answers that are not errors" do
    it "reports an empty file as empty" do
      with_file("") do |path|
        result = FsUtils::Reader.new(path).read

        result.empty_file?.should be_true
        result.total_lines.should eq 0
        result.first_line.should be_nil
        result.content.should eq ""
      end
    end

    it "reports an offset past the end" do
      with_file(numbered_lines) do |path|
        result = FsUtils::Reader.new(path, offset: 500).read

        result.past_end?.should be_true
        result.total_lines.should eq 10
        result.first_line.should be_nil
      end
    end
  end

  describe "budgets" do
    it "stops at the byte budget and says so" do
      with_file((1..500).map { |i| "#{i} #{"x" * 100}" }.join("\n") + "\n") do |path|
        result = FsUtils::Reader.new(path, max_bytes: 1_000).read

        result.truncated?.should be_true
        result.truncation_reason.should eq FsUtils::Reader::TruncationReason::ByteBudget
        result.lines_elided.should be > 0
        result.total_lines.should eq 500
      end
    end

    it "always returns at least one line, however long" do
      with_file("#{"x" * 50_000}\nsecond\n") do |path|
        result = FsUtils::Reader.new(path, max_bytes: 100).read

        result.first_line.should eq 1
        result.content.empty?.should be_false
      end
    end

    it "cuts a long line and marks it" do
      with_file("#{"x" * 5_000}\nshort\n") do |path|
        result = FsUtils::Reader.new(path, max_line_length: 100).read

        result.long_lines.should eq 1
        result.content.should contain "chars omitted"
      end
    end

    it "does not call a merely long-lined read truncated" do
      with_file("#{"x" * 5_000}\n") do |path|
        result = FsUtils::Reader.new(path, max_line_length: 100).read

        result.truncated?.should be_false
        result.truncation_reason.should eq FsUtils::Reader::TruncationReason::LongLines
      end
    end
  end

  describe "refusals" do
    it "rejects a non-positive offset or limit" do
      expect_raises(ArgumentError, /offset/) { FsUtils::Reader.new("x", offset: 0) }
      expect_raises(ArgumentError, /limit/) { FsUtils::Reader.new("x", limit: 0) }
    end

    it "rejects a path containing a null byte" do
      expect_raises(ArgumentError, /null/) { FsUtils::Reader.new("a\u0000b") }
    end

    it "refuses a directory" do
      expect_raises(FsUtils::Error, /directory/) do
        FsUtils::Reader.new(Dir.tempdir).read
      end
    end

    it "refuses a binary file" do
      with_file("text\u0000more\n") do |path|
        expect_raises(FsUtils::Error, /binary/) { FsUtils::Reader.new(path).read }
      end
    end

    it "refuses a file over the ceiling" do
      with_file(numbered_lines) do |path|
        expect_raises(FsUtils::Error, /ceiling/) do
          FsUtils::Reader.new(path, max_file_bytes: 5_i64).read
        end
      end
    end

    it "refuses a missing file" do
      expect_raises(FsUtils::Error, /does not exist/) do
        FsUtils::Reader.new("/definitely/not/here").read
      end
    end
  end
end
