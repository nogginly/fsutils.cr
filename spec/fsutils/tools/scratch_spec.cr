require "../../spec_helper"

private def with_scratch(max_inline_bytes : Int32 = 32_000, max_headings : Int32 = 200, &)
  root = ::File.join(Dir.tempdir, "fsutils-scratch-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(::File.join(root, "src"))
  ::File.write(::File.join(root, "src", "a.cr"), "puts 1\n")

  begin
    sandbox = FsUtils::Tools::Sandbox.new(root)
    settings = FsUtils::Tools::Scratch::Settings.new
    settings.max_inline_bytes = max_inline_bytes
    settings.max_headings = max_headings
    yield FsUtils::Tools::Scratch.new(sandbox, settings), root
  ensure
    FileUtils.rm_rf(root)
  end
end

private LONG = "# Title\n\nbody\n\n## Section\n\n#{"word " * 400}\n"

describe FsUtils::Tools::Scratch do
  it "returns small content inline and writes nothing" do
    with_scratch do |scratch, root|
      held = scratch.hold("https://example.com/a", "# Small\n", {} of String => String)

      held.should be_a FsUtils::Tools::Scratch::Inline
      Dir.exists?(::File.join(root, FsUtils::Tools::Scratch::DEFAULT_DIR)).should be_false
    end
  end

  it "writes content past the threshold, inside the sandbox" do
    with_scratch(max_inline_bytes: 100) do |scratch, root|
      stored = scratch.hold("https://example.com/a", LONG, {} of String => String)
        .as(FsUtils::Tools::Scratch::Stored)

      stored.path.should start_with FsUtils::Tools::Scratch::DEFAULT_DIR
      ::File.exists?(::File.join(root, stored.path)).should be_true
    end
  end

  # The file outlives the response, so where the content came from has to be
  # in the file rather than only in the fields around it.
  it "opens a stored file with front matter carrying its provenance" do
    with_scratch(max_inline_bytes: 100) do |scratch, root|
      held = scratch.hold("https://example.com/a", LONG,
        {"source" => "https://example.com/a", "title" => "A: the page"}).as(FsUtils::Tools::Scratch::Stored)

      document = ::File.read(::File.join(root, held.path))
      document.should start_with "---\n"
      document.should contain %(source: "https://example.com/a")
      document.should contain %(title: "A: the page")
    end
  end

  it "carries no clock, so the same content writes the same bytes" do
    with_scratch(max_inline_bytes: 100) do |scratch, root|
      first = scratch.store("https://example.com/a", LONG, {"source" => "https://example.com/a"})
      before = ::File.read(::File.join(root, first.path))
      second = scratch.store("https://example.com/a", LONG, {"source" => "https://example.com/a"})

      second.path.should eq first.path
      ::File.read(::File.join(root, second.path)).should eq before
    end
  end

  it "names different keys differently" do
    with_scratch(max_inline_bytes: 100) do |scratch, _|
      first = scratch.store("https://example.com/a", LONG, {} of String => String)
      second = scratch.store("https://example.com/b", LONG, {} of String => String)

      first.path.should_not eq second.path
    end
  end

  # Line numbers that ignore the preamble address a file that does not exist.
  it "counts the front matter in its heading line numbers" do
    with_scratch(max_inline_bytes: 100) do |scratch, root|
      held = scratch.store("https://example.com/a", LONG, {"source" => "https://example.com/a"})

      lines = ::File.read(::File.join(root, held.path)).lines
      heading = held.headings.first
      lines[heading.start_line - 1].should eq "# Title"
      held.lines.should eq lines.size
    end
  end

  it "reports an excerpt of the content, not of the preamble" do
    with_scratch(max_inline_bytes: 100) do |scratch, _|
      held = scratch.store("https://example.com/a", LONG, {"source" => "https://example.com/a"})

      held.excerpt.should start_with "# Title"
    end
  end

  # A page's shape is carried by its top two levels, so the deep headings go
  # before the list is cut.
  it "drops the deep headings when there are too many" do
    markdown = String.build do |io|
      30.times do |index|
        io << "## Section " << index << "\n\ntext\n\n"
        io << "### Detail " << index << "\n\ntext\n\n"
      end
    end

    with_scratch(max_inline_bytes: 100, max_headings: 40) do |scratch, _|
      held = scratch.store("https://example.com/many", markdown, {} of String => String)

      held.headings.size.should eq 30
      held.headings.map(&.level).uniq.should eq [2]
      held.headings_truncated.should be_true
    end
  end

  it "keeps every heading when they fit" do
    with_scratch(max_inline_bytes: 100, max_headings: 200) do |scratch, _|
      held = scratch.store("https://example.com/a", LONG, {} of String => String)

      held.headings.size.should eq 2
      held.headings_truncated.should be_false
    end
  end

  describe FsUtils::Tools::Scratch::Settings do
    it "refuses a directory outside the workspace" do
      settings = FsUtils::Tools::Scratch::Settings.new
      settings.dir = "/tmp/elsewhere"

      expect_raises(ArgumentError, /inside the workspace/) { settings.validate! }
    end

    it "refuses a blank directory" do
      settings = FsUtils::Tools::Scratch::Settings.new
      settings.dir = ""

      expect_raises(ArgumentError, /must not be blank/) { settings.validate! }
    end
  end
end
