require "../../spec_helper"

# Builds a sandbox root, a sibling that shares its name prefix, and a secret
# outside both.
#
#   base/
#     project/            <- the sandbox root
#       src/a.cr
#       nested/
#     project-secrets/    <- shares a prefix, is NOT inside
#       creds.txt
#     outside/secret.txt
private def with_sandbox(&)
  base = File.join(Dir.tempdir, "fsutils_sandbox_#{Random.rand(UInt32)}")
  root = File.join(base, "project")
  begin
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(root, "nested"))
    Dir.mkdir_p(File.join(base, "project-secrets"))
    Dir.mkdir_p(File.join(base, "outside"))

    File.write(File.join(root, "src", "a.cr"), "alpha\n")
    File.write(File.join(base, "project-secrets", "creds.txt"), "hunter2\n")
    File.write(File.join(base, "outside", "secret.txt"), "shh\n")

    yield FsUtils::Tools::Sandbox.new(root), root, base
  ensure
    FileUtils.rm_rf(base)
  end
end

describe FsUtils::Tools::Sandbox do
  describe "construction" do
    it "canonicalises the root" do
      with_sandbox do |sandbox, root, _|
        sandbox.root.should eq File.realpath(root)
        sandbox.root.ends_with?(File::SEPARATOR).should be_false
      end
    end

    it "rejects a root that does not exist" do
      expect_raises(FsUtils::Error, /unusable/) do
        FsUtils::Tools::Sandbox.new("/definitely/not/here")
      end
    end

    it "rejects a root that is not a directory" do
      with_sandbox do |_, root, _|
        expect_raises(FsUtils::Error, /not a directory/) do
          FsUtils::Tools::Sandbox.new(File.join(root, "src", "a.cr"))
        end
      end
    end
  end

  describe "#resolve" do
    it "resolves a relative path against the root" do
      with_sandbox do |sandbox, root, _|
        sandbox.resolve("src/a.cr").should eq File.join(File.realpath(root), "src", "a.cr")
      end
    end

    it "accepts an absolute path that lands inside" do
      with_sandbox do |sandbox, root, _|
        inside = File.join(File.realpath(root), "src", "a.cr")
        sandbox.resolve(inside).should eq inside
      end
    end

    it "treats an empty path as the root" do
      with_sandbox do |sandbox, _, _|
        sandbox.resolve("").should eq sandbox.root
      end
    end

    it "resolves paths that do not exist yet" do
      with_sandbox do |sandbox, _, _|
        sandbox.resolve("src/nope.cr").should eq File.join(sandbox.root, "src", "nope.cr")
        sandbox.resolve("no/such/dir/file.txt")
          .should eq File.join(sandbox.root, "no", "such", "dir", "file.txt")
      end
    end

    it "normalises . and harmless .. within the root" do
      with_sandbox do |sandbox, _, _|
        sandbox.resolve("./src/./a.cr").should eq File.join(sandbox.root, "src", "a.cr")
        sandbox.resolve("nested/../src/a.cr").should eq File.join(sandbox.root, "src", "a.cr")
      end
    end
  end

  describe "escapes" do
    it "refuses a relative path that climbs out" do
      with_sandbox do |sandbox, _, _|
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("../outside/secret.txt") }
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("src/../../outside") }
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("../../../../etc/passwd") }
      end
    end

    it "refuses an absolute path outside the root" do
      with_sandbox do |sandbox, _, base|
        expect_raises(FsUtils::Tools::Sandbox::Escape) do
          sandbox.resolve(File.join(base, "outside", "secret.txt"))
        end
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("/etc/passwd") }
      end
    end

    it "does not mistake a prefix-sharing sibling for the root" do
      with_sandbox do |sandbox, _, base|
        # `/…/project-secrets` starts with `/…/project`. A bare prefix test
        # would let this through.
        expect_raises(FsUtils::Tools::Sandbox::Escape) do
          sandbox.resolve(File.join(base, "project-secrets", "creds.txt"))
        end
      end
    end

    it "refuses a symlink inside the root pointing out of it" do
      with_sandbox do |sandbox, root, base|
        File.symlink(File.join(base, "outside"), File.join(root, "escape"))

        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("escape") }
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("escape/secret.txt") }
      end
    end

    it "allows a symlink that stays inside the root" do
      with_sandbox do |sandbox, root, _|
        File.symlink(File.join(root, "src"), File.join(root, "link"))

        sandbox.resolve("link/a.cr").should eq File.join(sandbox.root, "src", "a.cr")
      end
    end

    it "refuses a path laundered through a symlink and back out" do
      with_sandbox do |sandbox, root, base|
        File.symlink(base, File.join(root, "up"))

        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("up/outside/secret.txt") }
        expect_raises(FsUtils::Tools::Sandbox::Escape) { sandbox.resolve("up/project-secrets") }
      end
    end

    it "reports a dangling symlink as itself rather than resolving through it" do
      with_sandbox do |sandbox, root, _|
        File.symlink(File.join(root, "gone.txt"), File.join(root, "dangling"))

        sandbox.resolve("dangling").should eq File.join(sandbox.root, "dangling")
      end
    end
  end

  describe "#resolve_all" do
    it "defaults to the root when given nothing" do
      with_sandbox do |sandbox, _, _|
        sandbox.resolve_all([] of String).should eq [sandbox.root]
      end
    end

    it "resolves each path and refuses the whole set if any escapes" do
      with_sandbox do |sandbox, _, _|
        sandbox.resolve_all(["src", "nested"])
          .should eq [File.join(sandbox.root, "src"), File.join(sandbox.root, "nested")]

        expect_raises(FsUtils::Tools::Sandbox::Escape) do
          sandbox.resolve_all(["src", "../outside"])
        end
      end
    end
  end

  describe "#relative" do
    it "strips the root" do
      with_sandbox do |sandbox, _, _|
        sandbox.relative(File.join(sandbox.root, "src", "a.cr")).should eq "src/a.cr"
      end
    end

    it "calls the root itself ." do
      with_sandbox do |sandbox, _, _|
        sandbox.relative(sandbox.root).should eq "."
      end
    end

    it "leaves an outside path alone rather than mangling it" do
      with_sandbox do |sandbox, _, base|
        outside = File.join(base, "project-secrets", "creds.txt")
        sandbox.relative(outside).should eq outside
      end
    end
  end

  describe "#inside?" do
    it "accepts the root and its descendants" do
      with_sandbox do |sandbox, _, _|
        sandbox.inside?(sandbox.root).should be_true
        sandbox.inside?(File.join(sandbox.root, "src")).should be_true
      end
    end

    it "rejects a sibling sharing the root's name as a prefix" do
      with_sandbox do |sandbox, _, _|
        sandbox.inside?(sandbox.root + "-secrets").should be_false
        sandbox.inside?(sandbox.root + "x").should be_false
      end
    end
  end
end
