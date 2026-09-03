require "../spec_helper"

# Builds, once per run, a fixture tree:
#
#   root/
#     a.txt              (5 bytes)
#     b.cr
#     .hidden.txt
#     sub/
#       c.cr
#       deep/
#         d.txt
#     fat/               (30 x fat_NN.txt)
#     node_modules/
#       junk.cr
#     loop -> root       (symlink back to the top)
#     link.txt -> a.txt
private def with_tree(&)
  root = ::File.join(Dir.tempdir, "fs_utils_find_#{Random.rand(1 << 30)}")
  begin
    Dir.mkdir_p(::File.join(root, "sub", "deep"))
    Dir.mkdir_p(::File.join(root, "fat"))
    Dir.mkdir_p(::File.join(root, "node_modules"))

    ::File.write(::File.join(root, "a.txt"), "hello")
    ::File.write(::File.join(root, "b.cr"), "puts 1")
    ::File.write(::File.join(root, ".hidden.txt"), "shh")
    ::File.write(::File.join(root, "sub", "c.cr"), "x")
    ::File.write(::File.join(root, "sub", "deep", "d.txt"), "deep")
    ::File.write(::File.join(root, "node_modules", "junk.cr"), "nope")
    30.times { |i| ::File.write(::File.join(root, "fat", "fat_%02d.txt" % i), "x") }

    ::File.symlink(root, ::File.join(root, "loop"))
    ::File.symlink(::File.join(root, "a.txt"), ::File.join(root, "link.txt"))

    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def collect(root, **args) : {Array(String), FsUtils::Find::Report}
  paths = [] of String
  report = FsUtils::Find.new(root, **args).run { |m| paths << m.path }
  {paths, report}
end

private def names(paths)
  paths.map { |p| ::File.basename(p) }
end

describe FsUtils::Find do
  it "finds files by name glob" do
    with_tree do |root|
      paths, report = collect(root, name: ["*.cr"])
      names(paths).sort.should eq %w[b.cr c.cr]
      report.stop_reason.should eq FsUtils::Find::StopReason::Completed
      report.truncated?.should be_false
    end
  end

  it "skips deny-listed directories by default" do
    with_tree do |root|
      paths, _ = collect(root, name: ["junk.cr"])
      paths.should be_empty
    end
  end

  it "enters deny-listed directories when the list is cleared" do
    with_tree do |root|
      paths, _ = collect(root, name: ["junk.cr"], skip_dirs: [] of String)
      names(paths).should eq %w[junk.cr]
    end
  end

  it "honours max_matches and reports the reason" do
    with_tree do |root|
      paths, report = collect(root, name: ["*.txt"], max_matches: 3)
      paths.size.should eq 3
      report.matches.should eq 3
      report.stop_reason.should eq FsUtils::Find::StopReason::MaxMatches
      report.truncated?.should be_true
    end
  end

  it "stops one directory from dominating the results" do
    with_tree do |root|
      paths, report = collect(root, name: ["*.txt"], max_matches_per_dir: 5)
      fat = paths.count { |p| p.includes?("/fat/") }
      fat.should eq 5
      # The rest of the tree still gets a look in.
      names(paths).should contain "a.txt"
      names(paths).should contain "d.txt"
      report.truncated?.should be_false
    end
  end

  it "does not follow symlinked directories by default" do
    with_tree do |root|
      paths, report = collect(root, name: ["a.txt"])
      paths.size.should eq 1
      report.elapsed.total_seconds.should be < 5.0
    end
  end

  it "terminates on a symlink loop when following symlinks" do
    with_tree do |root|
      paths, report = collect(root, name: ["a.txt"], follow_symlinks: true)
      paths.size.should eq 1
      report.pruned.should be > 0
      report.stop_reason.should eq FsUtils::Find::StopReason::Completed
    end
  end

  it "filters by type" do
    with_tree do |root|
      dirs, _ = collect(root, type: FsUtils::Find::EntryType::Directory)
      names(dirs).sort.should eq %w[deep fat node_modules sub]

      links, _ = collect(root, type: FsUtils::Find::EntryType::Symlink)
      names(links).sort.should eq %w[link.txt loop]
    end
  end

  it "respects max_depth and min_depth" do
    with_tree do |root|
      shallow, _ = collect(root, name: ["*.txt"], max_depth: 1)
      names(shallow).should_not contain "d.txt"

      deep, _ = collect(root, name: ["*.txt"], min_depth: 3)
      names(deep).should eq %w[d.txt]
    end
  end

  it "can exclude hidden files" do
    with_tree do |root|
      with_hidden, _ = collect(root, name: [".hidden.txt"])
      with_hidden.size.should eq 1

      without, _ = collect(root, name: [".hidden.txt"], include_hidden: false)
      without.should be_empty
    end
  end

  it "matches globs against the full path" do
    with_tree do |root|
      paths, _ = collect(root, path: ["**/sub/*.cr"])
      names(paths).should eq %w[c.cr]
    end
  end

  it "applies exclude globs" do
    with_tree do |root|
      paths, _ = collect(root, name: ["*.cr"], exclude: ["b.*"])
      names(paths).should eq %w[c.cr]
    end
  end

  it "filters by size" do
    with_tree do |root|
      paths, _ = collect(root, type: FsUtils::Find::EntryType::File, min_size: 5_i64)
      names(paths).sort.should eq %w[a.txt b.cr]
    end
  end

  it "filters by modification time" do
    with_tree do |root|
      future, _ = collect(root, name: ["a.txt"], newer_than: Time.utc + 1.hour)
      future.should be_empty

      past, _ = collect(root, name: ["a.txt"], newer_than: Time.utc - 1.hour)
      past.size.should eq 1
    end
  end

  it "is case insensitive on request" do
    with_tree do |root|
      paths, _ = collect(root, name: ["A.TXT"], case_insensitive: true)
      names(paths).should eq %w[a.txt]
    end
  end

  it "yields matches with useful metadata" do
    with_tree do |root|
      match = nil.as(FsUtils::Find::Match?)
      FsUtils::Find.new(root, name: ["a.txt"]).run { |m| match = m }
      m = match.should_not be_nil
      m.name.should eq "a.txt"
      m.size.should eq 5
      m.depth.should eq 1
      m.file?.should be_true
      m.symlink?.should be_false
    end
  end

  it "collects errors instead of raising on a missing root" do
    _, report = collect("/definitely/not/a/real/path")
    report.matches.should eq 0
    report.errors.size.should be > 0
  end

  it "rejects nonsense arguments" do
    expect_raises(ArgumentError) { FsUtils::Find.new([] of String) }
    expect_raises(ArgumentError) { FsUtils::Find.new(".", max_matches: 0) }
  end
end
