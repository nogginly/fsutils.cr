require "../spec_helper"

# A policy that records everything offered to it and claims one match per
# entry. Deliberately a struct: policies live for exactly one `run`, and this
# also checks that `Walker(P)` is happy with a value type.
private class Collector
  include FsUtils::Walk::Policy

  getter entries = [] of FsUtils::Walk::Entry
  getter entered = [] of String
  getter left = [] of String

  def visit(entry : FsUtils::Walk::Entry, limit : Int32) : Int32
    @entries << entry
    1
  end

  def enter_dir(dir : String, depth : Int32) : Bool
    @entered << dir
    true
  end

  def leave_dir(dir : String, depth : Int32) : Nil
    @left << dir
  end

  def names : Array(String)
    @entries.map(&.name)
  end
end

# Refuses to descend into anything named `skipme`.
private class Pruner < Collector
  def enter_dir(dir : String, depth : Int32) : Bool
    return false if ::File.basename(dir) == "skipme"
    super
  end
end

# Claims more than it is allowed, to prove the walker clamps.
private class Greedy
  include FsUtils::Walk::Policy

  getter granted = [] of Int32

  def visit(entry : FsUtils::Walk::Entry, limit : Int32) : Int32
    @granted << limit
    limit + 100
  end
end

# Claims one match per entry and records the limit it was offered.
private class Modest
  include FsUtils::Walk::Policy

  getter granted = [] of Int32

  def visit(entry : FsUtils::Walk::Entry, limit : Int32) : Int32
    @granted << limit
    1
  end
end

# Builds a tree and yields its root, cleaning up afterwards.
private def with_tree(&)
  root = ::File.join(Dir.tempdir, "fsutils-walker-#{Random.rand(UInt32)}")
  Dir.mkdir_p(::File.join(root, "src", "deep", "deeper"))
  Dir.mkdir_p(::File.join(root, "docs"))
  Dir.mkdir_p(::File.join(root, ".hidden"))
  Dir.mkdir_p(::File.join(root, "node_modules", "pkg"))

  ::File.write(::File.join(root, "README.md"), "readme\n")
  ::File.write(::File.join(root, ".dotfile"), "dot\n")
  ::File.write(::File.join(root, "src", "a.cr"), "alpha\n")
  ::File.write(::File.join(root, "src", "b.cr"), "beta\n")
  ::File.write(::File.join(root, "src", "deep", "c.cr"), "gamma\n")
  ::File.write(::File.join(root, "src", "deep", "deeper", "d.cr"), "delta\n")
  ::File.write(::File.join(root, "docs", "guide.md"), "guide\n")
  ::File.write(::File.join(root, ".hidden", "secret.cr"), "shh\n")
  ::File.write(::File.join(root, "node_modules", "pkg", "index.js"), "noise\n")

  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe FsUtils::Walker do
  describe "construction" do
    it "rejects an empty root list" do
      expect_raises(ArgumentError, /at least one root/) do
        FsUtils::Walker.new(Collector.new, [] of String)
      end
    end

    it "rejects non-positive budgets" do
      expect_raises(ArgumentError, /max_matches/) do
        FsUtils::Walker.new(Collector.new, ["."], max_matches: 0)
      end
      expect_raises(ArgumentError, /max_depth/) do
        FsUtils::Walker.new(Collector.new, ["."], max_depth: -1)
      end
    end

    it "accepts a single root as a String" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run.stop_reason.completed?.should be_true
      end
    end
  end

  describe "traversal" do
    it "visits every entry it does not deliberately skip" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, root).run

        policy.names.should contain("README.md")
        policy.names.should contain("a.cr")
        policy.names.should contain("guide.md")
        report.stop_reason.completed?.should be_true
        report.truncated?.should be_false
      end
    end

    it "is breadth-first: shallow entries arrive before deep ones" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        depths = policy.entries.map(&.depth)
        depths.should eq(depths.sort)
      end
    end

    it "is deterministic across runs" do
      with_tree do |root|
        first = Collector.new
        second = Collector.new
        FsUtils::Walker.new(first, root).run
        FsUtils::Walker.new(second, root).run

        first.entries.map(&.path).should eq(second.entries.map(&.path))
      end
    end

    it "reports depth relative to the root" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        policy.entries.find { |e| e.name == "README.md" }.not_nil!.depth.should eq(1)
        policy.entries.find { |e| e.name == "a.cr" }.not_nil!.depth.should eq(2)
        policy.entries.find { |e| e.name == "c.cr" }.not_nil!.depth.should eq(3)
      end
    end

    it "classifies entry types and carries metadata" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        readme = policy.entries.find { |e| e.name == "README.md" }.not_nil!
        readme.file?.should be_true
        readme.directory?.should be_false
        readme.symlink?.should be_false
        readme.size.should eq(7_i64)

        policy.entries.find { |e| e.name == "src" }.not_nil!.directory?.should be_true
      end
    end
  end

  describe "hidden entries" do
    it "skips them by default" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        policy.names.should_not contain(".dotfile")
        policy.names.should_not contain("secret.cr")
      end
    end

    it "includes them on request" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root, include_hidden: true).run

        policy.names.should contain(".dotfile")
        policy.names.should contain("secret.cr")
      end
    end
  end

  describe "skip_dirs" do
    it "does not descend into the deny-list by default" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        # The directory itself is still offered; its contents are not walked.
        policy.names.should contain("node_modules")
        policy.names.should_not contain("index.js")
      end
    end

    it "walks everything when the deny-list is empty" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root, skip_dirs: [] of String).run

        policy.names.should contain("index.js")
      end
    end
  end

  describe "depth" do
    it "stops descending at max_depth" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root, max_depth: 2).run

        policy.names.should contain("a.cr")     # depth 2
        policy.names.should contain("deep")     # depth 2, offered but not entered
        policy.names.should_not contain("c.cr") # depth 3
      end
    end

    it "offers only the roots' children at max_depth 1" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root, max_depth: 1).run

        policy.entries.map(&.depth).uniq.should eq([1])
      end
    end
  end

  describe "budgets" do
    it "stops at max_matches and says so" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, root, max_matches: 3).run

        report.matches.should eq(3)
        policy.entries.size.should eq(3)
        report.stop_reason.max_matches?.should be_true
        report.truncated?.should be_true
      end
    end

    it "caps a single directory without abandoning its subtree" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, root, max_matches_per_dir: 1).run

        report.dirs_capped.should be > 0
        report.truncated?.should be_true
        # Still reached a subdirectory's contents despite the parent capping.
        policy.entries.map(&.depth).max.should be > 1
      end
    end

    it "clamps a policy that claims more than its limit" do
      with_tree do |root|
        policy = Greedy.new
        report = FsUtils::Walker.new(policy, root, max_matches: 2).run

        # One offer of 2, taken in full, and the walk is over.
        policy.granted.should eq([2])
        report.matches.should eq(2)
        report.stop_reason.max_matches?.should be_true
      end
    end

    it "narrows the limit it offers as the budget runs down" do
      with_tree do |root|
        policy = Modest.new
        report = FsUtils::Walker.new(policy, root, max_matches: 2).run

        policy.granted.should eq([2, 1])
        report.matches.should eq(2)
        report.stop_reason.max_matches?.should be_true
      end
    end

    it "stops when max_entries_scanned is exceeded" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, root, max_entries_scanned: 2).run

        report.stop_reason.max_entries_scanned?.should be_true
      end
    end

    it "stops on timeout" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, root, timeout: 0.seconds).run

        report.stop_reason.timeout?.should be_true
        report.truncated?.should be_true
      end
    end
  end

  describe "policy hooks" do
    it "brackets each directory with enter_dir and leave_dir" do
      with_tree do |root|
        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        policy.entered.should contain(root)
        policy.left.sort.should eq(policy.entered.sort)
      end
    end

    it "prunes a directory the policy refuses to enter" do
      with_tree do |root|
        Dir.mkdir_p(::File.join(root, "skipme"))
        ::File.write(::File.join(root, "skipme", "hidden.cr"), "nope\n")

        policy = Pruner.new
        report = FsUtils::Walker.new(policy, root).run

        policy.names.should contain("skipme")
        policy.names.should_not contain("hidden.cr")
        policy.left.should_not contain(::File.join(root, "skipme"))
        report.pruned.should be > 0
      end
    end
  end

  describe "roots" do
    it "accepts a plain file as a root" do
      with_tree do |root|
        file = ::File.join(root, "README.md")
        policy = Collector.new
        report = FsUtils::Walker.new(policy, file).run

        policy.names.should eq(["README.md"])
        policy.entries.first.depth.should eq(0)
        report.directories.should eq(0)
        report.stop_reason.completed?.should be_true
      end
    end

    it "deduplicates overlapping roots" do
      with_tree do |root|
        policy = Collector.new
        report = FsUtils::Walker.new(policy, [root, ::File.join(root, ".")]).run

        report.pruned.should be > 0
        policy.names.count("README.md").should eq(1)
      end
    end
  end

  describe "symlinks" do
    it "reports but does not follow them by default" do
      with_tree do |root|
        ::File.symlink(::File.join(root, "src"), ::File.join(root, "link"))

        policy = Collector.new
        FsUtils::Walker.new(policy, root).run

        link = policy.entries.find { |e| e.name == "link" }.not_nil!
        link.symlink?.should be_true
        link.type.symlink?.should be_true
        # src/a.cr is reached via src, once — not again via the link.
        policy.entries.count { |e| e.name == "a.cr" }.should eq(1)
      end
    end

    it "enters a cycle exactly once when following" do
      with_tree do |root|
        ::File.symlink(root, ::File.join(root, "src", "loop"))

        policy = Collector.new
        report = FsUtils::Walker.new(policy, root, follow_symlinks: true, max_depth: 8).run

        report.pruned.should be > 0
        report.stop_reason.completed?.should be_true
      end
    end
  end

  describe "errors" do
    it "collects a missing root rather than raising" do
      policy = Collector.new
      report = FsUtils::Walker.new(policy, "/definitely/not/here").run

      report.errors.size.should eq(1)
      report.stop_reason.completed?.should be_true
      policy.entries.should be_empty
    end

    it "survives an unreadable directory" do
      with_tree do |root|
        locked = ::File.join(root, "locked")
        Dir.mkdir_p(locked)
        ::File.write(::File.join(locked, "x.cr"), "x\n")
        ::File.chmod(locked, 0o000)

        policy = Collector.new
        report = FsUtils::Walker.new(policy, root).run

        report.stop_reason.completed?.should be_true
        policy.names.should contain("README.md")

        ::File.chmod(locked, 0o755)
      end
    end
  end

  describe "reuse" do
    it "reports the same thing when run twice" do
      with_tree do |root|
        walker = FsUtils::Walker.new(Collector.new, root)
        first = walker.run
        second = walker.run

        second.matches.should eq(first.matches)
        second.scanned.should eq(first.scanned)
        second.pruned.should eq(first.pruned)
      end
    end
  end
end
