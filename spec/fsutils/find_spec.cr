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

# A synthetic entry, for exercising the filter predicate without a filesystem.
private def entry(
  name : String,
  path : String? = nil,
  type : FsUtils::Walk::EntryType = FsUtils::Walk::EntryType::File,
  size : Int64 = 10_i64,
  depth : Int32 = 1,
  mtime : Time = Time.utc,
) : FsUtils::Walk::Entry
  FsUtils::Walk::Entry.new(
    path: path || "/root/#{name}",
    name: name,
    type: type,
    size: size,
    modification_time: mtime,
    depth: depth,
    symlink: type.symlink?,
  )
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
      # Completed the walk, but `fat` was capped — so this is still a sample.
      report.stop_reason.should eq FsUtils::Find::StopReason::Completed
      report.dirs_capped.should be > 0
      report.truncated?.should be_true
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

  it "excludes hidden entries by default" do
    with_tree do |root|
      without, _ = collect(root, name: [".hidden.txt"])
      without.should be_empty

      with_hidden, _ = collect(root, name: [".hidden.txt"], include_hidden: true)
      with_hidden.size.should eq 1
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
    expect_raises(ArgumentError) { FsUtils::Find.new(".", min_depth: -1) }
  end

  it "accepts several roots" do
    with_tree do |root|
      paths = [] of String
      FsUtils::Find.new(
        [::File.join(root, "sub"), ::File.join(root, "fat")],
        name: ["c.cr", "fat_00.txt"]
      ).run { |m| paths << m.path }

      names(paths).sort.should eq %w[c.cr fat_00.txt]
    end
  end
end

# Hoisted into the namespace so the private filter predicate is visible. These
# exercise the matching rules directly, without a filesystem in the way.
module FsUtils
  class Find
    describe Criteria do
      it "has no opinion when given no filters" do
        Criteria.new.matches?(entry("anything.cr")).should be_true
      end

      it "ORs within a glob list and ANDs across lists" do
        c = Criteria.new(name: ["*.cr", "*.md"], path: ["/root/*"])
        c.matches?(entry("a.cr")).should be_true
        c.matches?(entry("a.md")).should be_true
        c.matches?(entry("a.txt")).should be_false
        c.matches?(entry("a.cr", path: "/elsewhere/a.cr")).should be_false
      end

      it "matches path globs against the whole path, not the basename" do
        # A single `*` does not cross a `/`, hence the leading `**/`.
        Criteria.new(path: ["*.cr"]).matches?(entry("a.cr", path: "/root/src/a.cr")).should be_false
        Criteria.new(path: ["**/a.cr"]).matches?(entry("a.cr", path: "/root/src/a.cr")).should be_true
      end

      it "excludes on either the name or the path" do
        Criteria.new(exclude: ["*.cr"]).matches?(entry("a.cr")).should be_false
        Criteria.new(exclude: ["**/vendor/**"])
          .matches?(entry("a.cr", path: "/root/vendor/a.cr")).should be_false
      end

      it "lets exclude beat include" do
        Criteria.new(name: ["*.cr"], exclude: ["a.*"]).matches?(entry("a.cr")).should be_false
      end

      it "filters by type" do
        c = Criteria.new(type: Walk::EntryType::Directory)
        c.matches?(entry("src", type: Walk::EntryType::Directory)).should be_true
        c.matches?(entry("a.cr")).should be_false
      end

      it "applies size bounds to files only" do
        c = Criteria.new(min_size: 100_i64)
        c.matches?(entry("a.cr", size: 10_i64)).should be_false
        c.matches?(entry("a.cr", size: 200_i64)).should be_true
        # A directory's size is an implementation detail of the filesystem.
        c.matches?(entry("src", type: Walk::EntryType::Directory, size: 10_i64)).should be_true
      end

      it "applies time bounds exclusively at the boundary" do
        now = Time.utc
        Criteria.new(newer_than: now).matches?(entry("a.cr", mtime: now)).should be_false
        Criteria.new(newer_than: now).matches?(entry("a.cr", mtime: now + 1.second)).should be_true
        Criteria.new(older_than: now).matches?(entry("a.cr", mtime: now - 1.second)).should be_true
      end

      it "enforces min_depth" do
        c = Criteria.new(min_depth: 3)
        c.matches?(entry("a.cr", depth: 2)).should be_false
        c.matches?(entry("a.cr", depth: 3)).should be_true
      end

      it "folds case on both sides when asked" do
        c = Criteria.new(name: ["A.TXT"], case_insensitive: true)
        c.matches?(entry("a.txt")).should be_true
        Criteria.new(name: ["A.TXT"]).matches?(entry("a.txt")).should be_false
      end
    end
  end
end
