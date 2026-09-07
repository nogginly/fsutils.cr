require "../spec_helper"

describe FsUtils::Text do
  describe ".binary?" do
    it "calls a NUL byte binary" do
      FsUtils::Text.binary?(Bytes[104, 105, 0, 104]).should be_true
    end

    it "calls plain text not binary" do
      FsUtils::Text.binary?("hello\nworld\n".to_slice).should be_false
    end

    it "calls empty bytes not binary" do
      FsUtils::Text.binary?(Bytes.empty).should be_false
    end

    it "rewinds the file so the caller can read it afterwards" do
      path = File.join(Dir.tempdir, "fsutils_text_#{Random.rand(UInt32)}.txt")
      begin
        File.write(path, "alpha\nbeta\n")
        File.open(path) do |file|
          FsUtils::Text.binary?(file).should be_false
          file.gets.should eq "alpha"
        end
      ensure
        File.delete?(path)
      end
    end

    it "only sniffs the first block" do
      path = File.join(Dir.tempdir, "fsutils_text_#{Random.rand(UInt32)}.dat")
      begin
        # A NUL well past the sniff window is not seen, by design: reading the
        # whole file to decide whether to read the whole file is no bargain.
        File.write(path, "x" * (FsUtils::Text::SNIFF_BYTES + 10) + "\u0000")
        File.open(path) { |file| FsUtils::Text.binary?(file).should be_false }
      ensure
        File.delete?(path)
      end
    end
  end

  describe ".clamp" do
    it "leaves a short line alone" do
      FsUtils::Text.clamp("short", 10).should eq({"short", 0})
    end

    it "leaves a line of exactly the limit alone" do
      FsUtils::Text.clamp("1234567890", 10).should eq({"1234567890", 0})
    end

    it "cuts a long line and reports what was dropped" do
      text, omitted = FsUtils::Text.clamp("a" * 100, 10)
      text.size.should eq 10
      omitted.should eq 90
    end

    it "counts characters, not bytes" do
      # Cutting mid-codepoint would hand a model text it cannot read.
      text, omitted = FsUtils::Text.clamp("é" * 10, 4)
      text.should eq "éééé"
      omitted.should eq 6
    end
  end
end
