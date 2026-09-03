require "../spec_helper"

private def with_tree(&)
  root = File.join(Dir.tempdir, "fs_utils_grep_#{Random.rand(UInt32)}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def write(root : String, path : String, content : String)
  full = File.join(root, path)
  Dir.mkdir_p(File.dirname(full))
  File.write(full, content)
  full
end

private def collect(grep : FsUtils::Grep)
  matches = [] of FsUtils::Grep::Match
  summary = grep.run { |m| matches << m }
  {matches, summary}
end

describe FsUtils::Grep do
  it "finds matches with path, line and column" do
    with_tree do |root|
      write(root, "a.txt", "alpha\nbeta needle gamma\n")
      matches, summary = collect(FsUtils::Grep.new("needle", path: root))

      matches.size.should eq 1
      m = matches.first
      m.relative_path.should eq "a.txt"
      m.line_number.should eq 2
      m.column.should eq 6
      m.matched.should eq "needle"
      m.line.should eq "beta needle gamma"
      summary.stopped.should eq FsUtils::Grep::Stop::Complete
      summary.truncated?.should be_false
    end
  end

  it "searches a single file when handed one" do
    with_tree do |root|
      path = write(root, "solo.txt", "hit\nmiss\nhit\n")
      matches, _ = collect(FsUtils::Grep.new("hit", path: path))
      matches.size.should eq 2
      matches.first.relative_path.should eq "solo.txt"
    end
  end

  it "treats the pattern as a regex, or literally when asked" do
    with_tree do |root|
      write(root, "a.txt", "foo1\nfoo.\n")

      regex, _ = collect(FsUtils::Grep.new("foo.", path: root))
      regex.size.should eq 2

      literal, _ = collect(FsUtils::Grep.new("foo.", path: root, fixed_string: true))
      literal.size.should eq 1
      literal.first.line.should eq "foo."
    end
  end

  it "honours ignore_case" do
    with_tree do |root|
      write(root, "a.txt", "Needle\n")
      collect(FsUtils::Grep.new("needle", path: root)).first.size.should eq 0
      collect(FsUtils::Grep.new("needle", path: root, ignore_case: true)).first.size.should eq 1
    end
  end

  it "raises on an invalid pattern" do
    expect_raises(FsUtils::Grep::Error, /invalid pattern/) do
      FsUtils::Grep.new("(unclosed")
    end
  end

  it "raises when the path does not exist" do
    expect_raises(FsUtils::Grep::Error, /path not found/) do
      FsUtils::Grep.new("x", path: "/nope/nowhere").run { }
    end
  end

  describe "budgets" do
    it "stops at max_matches" do
      with_tree do |root|
        write(root, "a.txt", "hit\n" * 50)
        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          max_matches: 5, max_matches_per_file: 100))
        matches.size.should eq 5
        summary.stopped.should eq FsUtils::Grep::Stop::MaxMatches
        summary.truncated?.should be_true
      end
    end

    it "caps a single dominating file" do
      with_tree do |root|
        write(root, "loud.txt", "hit\n" * 500)
        write(root, "quiet.txt", "hit\n")

        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          max_matches_per_file: 3))

        matches.count { |m| m.relative_path == "loud.txt" }.should eq 3
        matches.count { |m| m.relative_path == "quiet.txt" }.should eq 1
        summary.files_capped.should eq 1
      end
    end

    it "caps a single dominating directory" do
      with_tree do |root|
        20.times { |i| write(root, "loud/f#{i}.txt", "hit\n" * 10) }
        write(root, "quiet/f.txt", "hit\n")

        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          max_matches_per_file: 5, max_matches_per_dir: 10))

        matches.count { |m| m.relative_path.starts_with?("loud/") }.should eq 10
        matches.count { |m| m.relative_path.starts_with?("quiet/") }.should eq 1
        summary.dirs_capped.should be >= 1
      end
    end

    it "spreads the budget across branches rather than draining the first" do
      with_tree do |root|
        # A deep, noisy branch that a depth-first walk would sink into.
        deep = "deep"
        10.times do |i|
          deep = File.join(deep, "level#{i}")
          write(root, File.join(deep, "f.txt"), "hit\n" * 20)
        end
        write(root, "zzz/shallow.txt", "hit\n")

        matches, _ = collect(FsUtils::Grep.new("hit", path: root,
          max_matches: 30, max_matches_per_file: 5))

        matches.any? { |m| m.relative_path.starts_with?("zzz/") }.should be_true
      end
    end
  end

  describe "Paths mode" do
    it "yields one match per file, describing the first hit" do
      with_tree do |root|
        write(root, "a.txt", "no\nhit here\nhit again\n")
        write(root, "b.txt", "hit\n" * 100)
        write(root, "c.txt", "nothing\n")

        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          mode: FsUtils::Grep::Mode::Paths))

        matches.map(&.relative_path).sort.should eq ["a.txt", "b.txt"]
        matches.find! { |m| m.relative_path == "a.txt" }.line_number.should eq 2
        summary.files_capped.should eq 0
        summary.truncated?.should be_false
      end
    end

    it "counts max_matches in files and ignores max_matches_per_file" do
      with_tree do |root|
        5.times { |i| write(root, "f#{i}.txt", "hit\n" * 50) }

        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          mode: FsUtils::Grep::Mode::Paths, max_matches: 3, max_matches_per_file: 20))

        matches.size.should eq 3
        matches.map(&.relative_path).uniq.size.should eq 3
        summary.stopped.should eq FsUtils::Grep::Stop::MaxMatches
      end
    end
  end

  describe "type filters" do
    it "expands type names into include globs" do
      with_tree do |root|
        write(root, "a.cr", "hit\n")
        write(root, "b.ecr", "hit\n")
        write(root, "c.py", "hit\n")
        write(root, "d.txt", "hit\n")

        matches, _ = collect(FsUtils::Grep.new("hit", path: root, types: ["cr", "py"]))
        matches.map(&.relative_path).sort.should eq ["a.cr", "b.ecr", "c.py"]
      end
    end

    it "unions types with an explicit include list" do
      with_tree do |root|
        write(root, "a.cr", "hit\n")
        write(root, "shard.yml", "hit\n")
        write(root, "d.txt", "hit\n")

        matches, _ = collect(FsUtils::Grep.new("hit", path: root,
          types: ["cr"], include: ["*.yml"]))
        matches.map(&.relative_path).sort.should eq ["a.cr", "shard.yml"]
      end
    end

    it "raises on an unknown type" do
      expect_raises(FsUtils::Grep::Error, /unknown type/) do
        FsUtils::Grep.new("x", types: ["cobol"])
      end
    end
  end

  describe "guard rails" do
    it "skips binary files" do
      with_tree do |root|
        File.write(File.join(root, "bin.dat"), "hit\u0000hit\n")
        write(root, "text.txt", "hit\n")

        matches, summary = collect(FsUtils::Grep.new("hit", path: root))
        matches.map(&.relative_path).should eq ["text.txt"]
        summary.files_skipped.should eq 1
      end
    end

    it "skips oversized files" do
      with_tree do |root|
        write(root, "big.txt", "hit\n" * 1000)
        _, summary = collect(FsUtils::Grep.new("hit", path: root, max_file_bytes: 10_i64))
        summary.matches.should eq 0
        summary.files_skipped.should eq 1
      end
    end

    it "truncates very long lines" do
      with_tree do |root|
        write(root, "min.js", "x" * 50 + "hit" + "y" * 5000)
        matches, _ = collect(FsUtils::Grep.new("hit", path: root, max_line_length: 80))
        matches.first.line.size.should eq 80
        matches.first.truncated_line?.should be_true
      end
    end

    it "ignores hidden entries and skip_dirs by default" do
      with_tree do |root|
        write(root, ".hidden.txt", "hit\n")
        write(root, "node_modules/pkg.txt", "hit\n")
        write(root, "src/ok.txt", "hit\n")

        matches, _ = collect(FsUtils::Grep.new("hit", path: root))
        matches.map(&.relative_path).should eq ["src/ok.txt"]
      end
    end

    it "applies include and exclude globs" do
      with_tree do |root|
        write(root, "a.cr", "hit\n")
        write(root, "b.txt", "hit\n")
        write(root, "c.cr", "hit\n")

        included, _ = collect(FsUtils::Grep.new("hit", path: root, include: ["*.cr"]))
        included.map(&.relative_path).sort.should eq ["a.cr", "c.cr"]

        excluded, _ = collect(FsUtils::Grep.new("hit", path: root, exclude: ["*.cr"]))
        excluded.map(&.relative_path).should eq ["b.txt"]
      end
    end

    it "respects max_depth" do
      with_tree do |root|
        write(root, "top.txt", "hit\n")
        write(root, "one/two/deep.txt", "hit\n")

        matches, _ = collect(FsUtils::Grep.new("hit", path: root, max_depth: 1))
        matches.map(&.relative_path).should eq ["top.txt"]
      end
    end
  end

  describe "symlinks" do
    it "does not follow symlinks by default" do
      with_tree do |root|
        write(root, "real/a.txt", "hit\n")
        File.symlink(File.join(root, "real"), File.join(root, "link"))

        matches, _ = collect(FsUtils::Grep.new("hit", path: root))
        matches.map(&.relative_path).should eq ["real/a.txt"]
      end
    end

    it "does not loop on a symlink pointing back at a parent" do
      with_tree do |root|
        write(root, "real/a.txt", "hit\n")
        File.symlink(root, File.join(root, "real", "loop"))

        matches, summary = collect(FsUtils::Grep.new("hit", path: root,
          follow_symlinks: true, timeout: 5.seconds))

        matches.size.should eq 1
        summary.stopped.should eq FsUtils::Grep::Stop::Complete
      end
    end
  end
end
