require "../spec_helper"

private def with_dir(&)
  dir = File.join(Dir.tempdir, "fsutils_writer_#{Random.rand(UInt32)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe FsUtils::Writer do
  describe "creating" do
    it "writes the content exactly as supplied" do
      with_dir do |dir|
        path = File.join(dir, "a.txt")
        result = FsUtils::Writer.new(path, "no trailing newline").write

        File.read(path).should eq "no trailing newline"
        result.created.should be_true
        result.bytes_written.should eq 19
      end
    end

    it "appends nothing and normalises nothing" do
      with_dir do |dir|
        path = File.join(dir, "crlf.txt")
        FsUtils::Writer.new(path, "a\r\nb").write

        File.read(path).should eq "a\r\nb"
      end
    end

    it "writes an empty file for empty content" do
      with_dir do |dir|
        path = File.join(dir, "empty.txt")
        result = FsUtils::Writer.new(path, "").write

        File.exists?(path).should be_true
        result.bytes_written.should eq 0
        result.lines.should eq 0
      end
    end

    it "counts lines from disk" do
      with_dir do |dir|
        result = FsUtils::Writer.new(File.join(dir, "a.txt"), "one\ntwo\nthree\n").write
        result.lines.should eq 3
      end
    end
  end

  describe "replacing" do
    it "reports created false and does not ask permission" do
      with_dir do |dir|
        path = File.join(dir, "a.txt")
        File.write(path, "old\n")

        result = FsUtils::Writer.new(path, "new\n").write

        result.created.should be_false
        File.read(path).should eq "new\n"
      end
    end

    it "keeps the destination's permissions" do
      with_dir do |dir|
        path = File.join(dir, "a.txt")
        File.write(path, "old\n")
        File.chmod(path, 0o640)

        FsUtils::Writer.new(path, "new\n").write

        File.info(path).permissions.should eq File::Permissions.new(0o640)
      end
    end

    it "leaves no temporary files behind" do
      with_dir do |dir|
        FsUtils::Writer.new(File.join(dir, "a.txt"), "x\n").write
        Dir.children(dir).should eq ["a.txt"]
      end
    end
  end

  describe "parents" do
    it "creates missing directories and reports them in order" do
      with_dir do |dir|
        path = File.join(dir, "one", "two", "a.txt")
        result = FsUtils::Writer.new(path, "x\n").write

        result.parents_created.should eq [File.join(dir, "one"), File.join(dir, "one", "two")]
        File.read(path).should eq "x\n"
      end
    end

    it "reports nothing when the parent already exists" do
      with_dir do |dir|
        FsUtils::Writer.new(File.join(dir, "a.txt"), "x\n").write.parents_created.should be_empty
      end
    end

    it "refuses when a path segment is a file" do
      with_dir do |dir|
        File.write(File.join(dir, "blocker"), "x\n")

        expect_raises(FsUtils::Error, /not a directory/) do
          FsUtils::Writer.new(File.join(dir, "blocker", "a.txt"), "x\n").write
        end
      end
    end
  end

  describe "refusals" do
    it "rejects a path containing a null byte" do
      expect_raises(ArgumentError, /null/) { FsUtils::Writer.new("a\u0000b", "x") }
    end

    it "rejects content over the ceiling, before touching disk" do
      with_dir do |dir|
        path = File.join(dir, "a.txt")
        expect_raises(FsUtils::Error, /ceiling/) do
          FsUtils::Writer.new(path, "x" * 100, max_content_bytes: 10_i64)
        end
        File.exists?(path).should be_false
      end
    end

    it "refuses a directory" do
      with_dir do |dir|
        expect_raises(FsUtils::Error, /is a directory/) do
          FsUtils::Writer.new(dir, "x\n").write
        end
      end
    end
  end

  describe "atomicity" do
    it "leaves the original intact when the write cannot complete" do
      with_dir do |dir|
        path = File.join(dir, "a.txt")
        File.write(path, "original\n")
        File.chmod(dir, 0o500)

        begin
          FsUtils::Writer.new(path, "replacement\n").write
        rescue
          # Expected: the directory is not writable, so the temp file fails.
        end

        File.chmod(dir, 0o700)
        File.read(path).should eq "original\n"
      end
    end
  end
end
