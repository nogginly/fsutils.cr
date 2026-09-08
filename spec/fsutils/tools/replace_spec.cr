require "../../spec_helper"

private def with_replace_tools(&)
  base = File.join(Dir.tempdir, "fsutils_replace_#{Random.rand(UInt32)}")
  root = File.join(base, "workspace")
  begin
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(base, "outside"))

    File.write(File.join(root, "src", "harness.cr"),
      (1..20).map { |i| i == 10 ? "  raise UnknownTool.new(call.name)" : "  line #{i}" }
        .join("\n") + "\n")
    File.write(File.join(root, "src", "many.cr"), "x\na\nx\nb\nx\n")
    File.write(File.join(root, "bin.dat"), "text\u0000more\n")
    File.write(File.join(base, "outside", "secret.txt"), "target\n")

    yield FsUtils::Tools.new(root), root, base
  ensure
    FileUtils.rm_rf(base)
  end
end

private def replace_json(response) : JSON::Any
  JSON.parse(response.to_json)
end

describe "FsUtils::Tools#text_replace" do
  describe "replacing" do
    it "replaces a unique occurrence and shows the work" do
      with_replace_tools do |tools, root, _|
        json = replace_json(tools.text_replace(
          path: "src/harness.cr",
          old_string: "UnknownTool.new(call.name)",
          new_string: "UnknownTool.new(call.name, near: call.site)"))

        json["ok"].as_bool.should be_true
        json["path"].as_s.should eq "src/harness.cr"
        json["replacements"].as_i.should eq 1
        json["lines_delta"].as_i.should eq 0

        hunk = json["hunks"][0]
        hunk["changed_lines"].as_a.map(&.as_i).should eq [10]
        hunk["before"].as_s.should contain "UnknownTool.new(call.name)"
        hunk["after"].as_s.should contain "near: call.site"
        File.read(File.join(root, "src", "harness.cr")).should contain "call.site"
      end
    end

    it "replaces every occurrence when asked" do
      with_replace_tools do |tools, root, _|
        json = replace_json(tools.text_replace(
          path: "src/many.cr", old_string: "x", new_string: "y", replace_all: true))

        json["replacements"].as_i.should eq 3
        File.read(File.join(root, "src", "many.cr")).should eq "y\na\ny\nb\ny\n"
      end
    end

    it "notices when line numbers below the change have moved" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "src/harness.cr", old_string: "  line 5", new_string: "  line 5\n  extra"))

        json["lines_delta"].as_i.should eq 1
        json["notice"].as_s.should contain "line numbers below"
      end
    end

    it "omits what has nothing to say" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "src/harness.cr", old_string: "  line 5", new_string: "  line five"))

        json.as_h.has_key?("notice").should be_false
        json.as_h.has_key?("hunks_omitted").should be_false
        json.as_h.has_key?("error").should be_false
      end
    end
  end

  describe "refusals" do
    it "refuses several matches and names every line" do
      with_replace_tools do |tools, root, _|
        json = replace_json(tools.text_replace(
          path: "src/many.cr", old_string: "x", new_string: "y"))

        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "not_unique"
        json["error"]["message"].as_s.should contain "1, 3, 5"
        json["error"]["suggestion"].as_s.should contain "replace_all"
        File.read(File.join(root, "src", "many.cr")).should eq "x\na\nx\nb\nx\n"
      end
    end

    it "diagnoses an indentation-only difference" do
      with_replace_tools do |tools, _, _|
        # Second line lacks the file's two-space indent, so the newline makes
        # this a genuine mismatch rather than a substring.
        json = replace_json(tools.text_replace(
          path: "src/harness.cr",
          old_string: "  line 9\nraise UnknownTool.new(call.name)",
          new_string: "  line 9\n  raise Missing.new"))

        json["error"]["code"].as_s.should eq "no_match"
        json["error"]["suggestion"].as_s.should contain "indentation"
      end
    end

    it "refuses an empty old_string" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "src/harness.cr", old_string: "", new_string: "x"))

        json["error"]["code"].as_s.should eq "empty_old_string"
      end
    end

    it "refuses identical strings" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "src/harness.cr", old_string: "same", new_string: "same"))

        json["error"]["code"].as_s.should eq "strings_identical"
      end
    end

    it "refuses binary content" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "bin.dat", old_string: "text", new_string: "x"))

        json["error"]["code"].as_s.should eq "binary_content"
      end
    end

    it "refuses a path outside the workspace" do
      with_replace_tools do |tools, _, base|
        json = replace_json(tools.text_replace(
          path: "../outside/secret.txt", old_string: "target", new_string: "x"))

        json["error"]["code"].as_s.should eq "path_outside_sandbox"
        File.read(File.join(base, "outside", "secret.txt")).should eq "target\n"
      end
    end

    it "distinguishes a missing file" do
      with_replace_tools do |tools, _, _|
        json = replace_json(tools.text_replace(
          path: "src/nope.cr", old_string: "a", new_string: "b"))

        json["error"]["code"].as_s.should eq "path_not_found"
      end
    end

    it "never leaks an absolute host path" do
      with_replace_tools do |tools, root, _|
        replace_json(tools.text_replace(
          path: "src/many.cr", old_string: "x", new_string: "y", replace_all: true))
          .to_json.should_not contain root
      end
    end
  end

  it "ships a valid schema" do
    schema = JSON.parse(FsUtils::Tools::REPLACE_SCHEMA)
    schema["name"].as_s.should eq "text_replace"
    schema["input_schema"]["required"].as_a.map(&.as_s)
      .should eq ["path", "old_string", "new_string"]
  end
end
