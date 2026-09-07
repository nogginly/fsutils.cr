require "../../spec_helper"

private def with_write_tools(&)
  base = File.join(Dir.tempdir, "fsutils_write_#{Random.rand(UInt32)}")
  root = File.join(base, "workspace")
  begin
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(base, "outside"))
    File.write(File.join(root, "src", "a.cr"), (1..40).map { |i| "line #{i}" }.join("\n") + "\n")

    yield FsUtils::Tools.new(root), root, base
  ensure
    FileUtils.rm_rf(base)
  end
end

private def write_json(response) : JSON::Any
  JSON.parse(response.to_json)
end

describe "FsUtils::Tools#write" do
  describe "creating" do
    it "writes a new file and says it created one" do
      with_write_tools do |tools, root, _|
        json = write_json(tools.write(path: "src/new.cr", content: "puts 1\n"))

        json["ok"].as_bool.should be_true
        json["created"].as_bool.should be_true
        json["path"].as_s.should eq "src/new.cr"
        json["lines"].as_i.should eq 1
        File.read(File.join(root, "src", "new.cr")).should eq "puts 1\n"
      end
    end

    it "reports parent directories relative to the workspace" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "a/b/c.txt", content: "x\n"))

        json["parents_created"].as_a.map(&.as_s).should eq ["a", "a/b"]
        json["notice"].as_s.should contain "directory levels"
      end
    end

    it "ignores overwrite when the path does not exist" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "src/new.cr", content: "x\n", overwrite: true))
        json["created"].as_bool.should be_true
      end
    end

    it "omits what has nothing to say" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "src/new.cr", content: "x\n"))

        json.as_h.has_key?("notice").should be_false
        json.as_h.has_key?("error").should be_false
        json.as_h.has_key?("truncated").should be_false
      end
    end
  end

  describe "the overwrite guard" do
    it "refuses an existing file without the flag, and says what would be lost" do
      with_write_tools do |tools, root, _|
        json = write_json(tools.write(path: "src/a.cr", content: "clobbered\n"))

        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "file_exists"
        json["error"]["message"].as_s.should contain "40 lines"
        json["error"]["suggestion"].as_s.should contain "overwrite"
        # Nothing was written.
        File.read(File.join(root, "src", "a.cr")).should contain "line 1"
      end
    end

    it "replaces with the flag, and reports created false" do
      with_write_tools do |tools, root, _|
        json = write_json(tools.write(path: "src/a.cr", content: "new\n", overwrite: true))

        json["ok"].as_bool.should be_true
        json["created"].as_bool.should be_false
        File.read(File.join(root, "src", "a.cr")).should eq "new\n"
      end
    end

    it "warns when a replacement shrinks a file sharply" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "src/a.cr", content: "one\n", overwrite: true))

        json["notice"].as_s.should contain "Replaced 40 lines with 1"
        json["notice"].as_s.should contain "not recoverable"
      end
    end

    it "says nothing about a replacement of similar size" do
      with_write_tools do |tools, _, _|
        content = (1..38).map { |i| "x #{i}" }.join("\n") + "\n"
        json = write_json(tools.write(path: "src/a.cr", content: content, overwrite: true))

        json.as_h.has_key?("notice").should be_false
      end
    end
  end

  describe "failures" do
    it "refuses a path outside the workspace" do
      with_write_tools do |tools, _, base|
        json = write_json(tools.write(path: "../outside/x.txt", content: "x\n"))

        json["error"]["code"].as_s.should eq "path_outside_sandbox"
        File.exists?(File.join(base, "outside", "x.txt")).should be_false
      end
    end

    it "does not create parent directories outside the workspace" do
      with_write_tools do |tools, _, base|
        json = write_json(tools.write(path: "../outside/deep/nested/x.txt", content: "x\n"))

        json["ok"].as_bool.should be_false
        Dir.exists?(File.join(base, "outside", "deep")).should be_false
      end
    end

    it "refuses a directory" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "src", content: "x\n", overwrite: true))
        json["error"]["code"].as_s.should eq "is_directory"
      end
    end

    it "refuses when a path segment is a file" do
      with_write_tools do |tools, _, _|
        json = write_json(tools.write(path: "src/a.cr/nested.txt", content: "x\n"))
        json["error"]["code"].as_s.should eq "parent_not_directory"
      end
    end

    it "never leaks an absolute host path" do
      with_write_tools do |tools, root, _|
        write_json(tools.write(path: "a/b/c.txt", content: "x\n")).to_json
          .should_not contain root
      end
    end
  end

  it "ships a valid schema" do
    schema = JSON.parse(FsUtils::Tools::WRITE_SCHEMA)
    schema["name"].as_s.should eq "write_text_file"
    schema["input_schema"]["required"].as_a.map(&.as_s).should eq ["path", "content"]
  end
end
