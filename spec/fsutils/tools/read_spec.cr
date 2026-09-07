require "../../spec_helper"

private def with_read_tools(&)
  base = File.join(Dir.tempdir, "fsutils_read_#{Random.rand(UInt32)}")
  root = File.join(base, "workspace")
  begin
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(base, "outside"))

    File.write(File.join(root, "src", "a.cr"), (1..10).map { |i| "line #{i}" }.join("\n") + "\n")
    File.write(File.join(root, "empty.txt"), "")
    File.write(File.join(root, "bin.dat"), "text\u0000more\n")
    # Big enough to exceed the reader's 256 KB budget: ~2000 lines of ~200
    # bytes. Anything smaller returns whole and truncates nothing.
    File.write(File.join(root, "long.txt"), (1..2_000).map { |i| "#{i} #{"y" * 200}" }.join("\n") + "\n")
    File.write(File.join(base, "outside", "secret.txt"), "shh\n")

    yield FsUtils::Tools.new(root), root, base
  ensure
    FileUtils.rm_rf(base)
  end
end

private def read_json(response) : JSON::Any
  JSON.parse(response.to_json)
end

describe "FsUtils::Tools#read" do
  it "returns numbered content with a workspace-relative path" do
    with_read_tools do |tools, _, _|
      json = read_json(tools.read(path: "src/a.cr"))

      json["ok"].as_bool.should be_true
      json["path"].as_s.should eq "src/a.cr"
      json["total_lines"].as_i.should eq 10
      json["range"]["first_line"].as_i.should eq 1
      json["range"]["last_line"].as_i.should eq 10
      json["content"].as_s.should contain "\tline 1"
    end
  end

  it "omits everything that has nothing to say" do
    with_read_tools do |tools, _, _|
      json = read_json(tools.read(path: "src/a.cr"))

      json.as_h.has_key?("truncated").should be_false
      json.as_h.has_key?("notice").should be_false
      json.as_h.has_key?("truncation_reason").should be_false
      json.as_h.has_key?("error").should be_false
    end
  end

  it "returns raw content when numbering is off" do
    with_read_tools do |tools, _, _|
      json = read_json(tools.read(path: "src/a.cr", line_numbers: false))
      json["content"].as_s.should start_with "line 1\n"
    end
  end

  it "opens at an explicit offset" do
    with_read_tools do |tools, _, _|
      json = read_json(tools.read(path: "src/a.cr", offset: 4, limit: 2))

      json["range"]["first_line"].as_i.should eq 4
      json["content"].as_s.should contain "line 4"
      json["content"].as_s.should_not contain "line 6"
    end
  end

  describe "the two truncation policies" do
    it "gives an implicit overflow a partial view and a way to continue" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "long.txt"))

        json["ok"].as_bool.should be_true
        json["truncated"].as_bool.should be_true
        json["notice"].as_s.should contain "PARTIAL"
        json["notice"].as_s.should contain "offset:"
        json["truncation_reason"].as_s.should eq "byte_budget"
        json["total_lines"].as_i.should eq 2_000
      end
    end

    it "makes an explicit overflow an error instead" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "long.txt", offset: 1, limit: 2_000))

        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "range_too_large"
        json["error"]["suggestion"].as_s.should contain "limit"
      end
    end

    it "treats a limit alone as explicit" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "long.txt", limit: 2_000))
        json["ok"].as_bool.should be_false
      end
    end
  end

  describe "answers that are not errors" do
    it "says an empty file is empty rather than missing" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "empty.txt"))

        json["ok"].as_bool.should be_true
        json["total_lines"].as_i.should eq 0
        json["notice"].as_s.should contain "empty"
      end
    end

    it "says an offset is past the end, and how far" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "src/a.cr", offset: 500))

        json["ok"].as_bool.should be_true
        json["notice"].as_s.should contain "past the end"
        json["notice"].as_s.should contain "10"
      end
    end
  end

  describe "failures" do
    it "refuses a path outside the workspace" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "../outside/secret.txt"))
        json["error"]["code"].as_s.should eq "path_outside_sandbox"
      end
    end

    it "distinguishes a missing file from an empty one" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "src/nope.cr"))
        json["error"]["code"].as_s.should eq "path_not_found"
        json["error"]["suggestion"].as_s.should contain "find_files"
      end
    end

    it "refuses a directory and says what to do" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "src"))
        json["error"]["code"].as_s.should eq "is_directory"
        json["error"]["suggestion"].as_s.should_not be_empty
      end
    end

    it "refuses binary content" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "bin.dat"))
        json["error"]["code"].as_s.should eq "binary_content"
      end
    end

    it "rejects a zero offset without raising" do
      with_read_tools do |tools, _, _|
        json = read_json(tools.read(path: "src/a.cr", offset: 0))
        json["error"]["code"].as_s.should eq "invalid_argument"
      end
    end

    it "never leaks an absolute host path" do
      with_read_tools do |tools, root, _|
        read_json(tools.read(path: "src/a.cr")).to_json.should_not contain root
      end
    end
  end

  it "ships a valid schema" do
    schema = JSON.parse(FsUtils::Tools::READ_SCHEMA)
    schema["name"].as_s.should eq "read_text_file"
    schema["input_schema"]["required"].as_a.map(&.as_s).should eq ["path"]
  end
end
