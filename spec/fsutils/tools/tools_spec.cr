require "../../spec_helper"

private def with_tools(**args, &)
  base = File.join(Dir.tempdir, "fsutils_tools_#{Random.rand(UInt32)}")
  root = File.join(base, "workspace")
  begin
    Dir.mkdir_p(File.join(root, "src"))
    Dir.mkdir_p(File.join(base, "outside"))

    File.write(File.join(root, "README.md"), "readme\n")
    File.write(File.join(root, "src", "a.cr"), "alpha\n# TODO tidy this\n")
    File.write(File.join(root, "src", "b.cr"), "beta\n")
    File.write(File.join(base, "outside", "secret.txt"), "TODO hunter2\n")

    yield FsUtils::Tools.new(root, **args), root, base
  ensure
    FileUtils.rm_rf(base)
  end
end

private def parse(response) : JSON::Any
  JSON.parse(response.to_json)
end

describe FsUtils::Tools do
  describe "#find" do
    it "returns results with paths relative to the workspace" do
      with_tools do |tools, _, _|
        json = parse(tools.find(name: ["*.cr"]))

        json["ok"].as_bool.should be_true
        json["results"].as_a.map { |r| r["path"].as_s }.sort.should eq ["src/a.cr", "src/b.cr"]
        json["results"][0]["type"].as_s.should eq "file"
        json["summary"]["matches"].as_i.should eq 2
        json["stop_reason"].as_s.should eq "completed"
      end
    end

    it "omits absent fields rather than emitting nulls" do
      with_tools do |tools, _, _|
        json = parse(tools.find(name: ["*.cr"]))

        json.as_h.has_key?("notice").should be_false
        json.as_h.has_key?("errors").should be_false
        json.as_h.has_key?("truncated").should be_false
        json.as_h.has_key?("error").should be_false
      end
    end

    it "filters by type" do
      with_tools do |tools, _, _|
        json = parse(tools.find(type: "directory"))
        json["results"].as_a.map { |r| r["path"].as_s }.should eq ["src"]
      end
    end

    it "rejects an unknown type without raising" do
      with_tools do |tools, _, _|
        json = parse(tools.find(type: "socket"))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "invalid_argument"
      end
    end
  end

  describe "#grep" do
    it "returns matches with line and column" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "TODO"))

        json["ok"].as_bool.should be_true
        result = json["results"][0]
        result["path"].as_s.should eq "src/a.cr"
        result["line"].as_i.should eq 2
        result["column"].as_i.should eq 3
        json["summary"]["files_scanned"].as_i.should be > 0
      end
    end

    it "supports paths mode" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "a", mode: "paths"))
        paths = json["results"].as_a.map { |r| r["path"].as_s }
        paths.should eq paths.uniq
      end
    end

    it "reports an invalid pattern as an error, not an exception" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "(unclosed"))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "invalid_pattern"
        json["error"]["message"].as_s.should contain "pattern"
      end
    end

    it "reports an unknown mode as an invalid argument" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "x", mode: "sideways"))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "invalid_argument"
      end
    end

    it "reports an unknown type name" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "x", types: ["cobol"]))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "invalid_argument"
      end
    end
  end

  describe "the sandbox" do
    it "refuses a path that climbs out" do
      with_tools do |tools, _, _|
        json = parse(tools.grep(pattern: "TODO", paths: ["../outside"]))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "path_outside_sandbox"
      end
    end

    it "refuses an absolute path outside the workspace" do
      with_tools do |tools, _, base|
        json = parse(tools.find(paths: [File.join(base, "outside")]))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "path_outside_sandbox"
      end
    end

    it "refuses a symlink pointing out of the workspace" do
      with_tools do |tools, root, base|
        File.symlink(File.join(base, "outside"), File.join(root, "escape"))
        json = parse(tools.grep(pattern: "TODO", paths: ["escape"]))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "path_outside_sandbox"
      end
    end

    it "distinguishes a missing path from an escaping one" do
      with_tools do |tools, _, _|
        json = parse(tools.find(paths: ["nope"]))
        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "path_not_found"
        json["error"]["message"].as_s.should contain "nope"
      end
    end

    it "never leaks an absolute host path" do
      with_tools do |tools, root, _|
        json = parse(tools.find(name: ["*.cr"]))
        json.to_json.should_not contain root
      end
    end
  end

  describe "truncation" do
    it "sets truncated and a notice when matches run out" do
      with_tools do |tools, root, _|
        20.times { |i| File.write(File.join(root, "src", "f#{i}.cr"), "hit\n") }

        json = parse(tools.grep(pattern: "hit", max_matches: 3))

        json["truncated"].as_bool.should be_true
        json["stop_reason"].as_s.should eq "max_matches"
        json["notice"].as_s.should contain "there may be more"
        json["results"].as_a.size.should eq 3
      end
    end

    it "suggests paths mode when files hit their per-file quota" do
      with_tools do |tools, root, _|
        File.write(File.join(root, "src", "loud.cr"), "hit\n" * 50)

        json = parse(tools.grep(pattern: "hit", max_matches_per_file: 2))

        json["truncated"].as_bool.should be_true
        json["notice"].as_s.should contain "paths"
      end
    end

    it "drops results that do not fit the output budget" do
      with_tools(max_output_bytes: 2_000) do |tools, root, _|
        50.times { |i| File.write(File.join(root, "src", "f#{i}.cr"), "#{"x" * 200} hit\n") }

        json = parse(tools.grep(pattern: "hit", max_matches: 50))

        json.to_json.bytesize.should be < 4_000
        json["truncated"].as_bool.should be_true
        json["notice"].as_s.should contain "output budget"
        # The summary still reports what was actually found.
        json["summary"]["matches"].as_i.should be > json["results"].as_a.size
      end
    end
  end

  describe "errors" do
    it "collects filesystem trouble without failing the call" do
      with_tools do |tools, root, _|
        locked = File.join(root, "src", "locked")
        Dir.mkdir_p(locked)
        File.write(File.join(locked, "x.cr"), "hit\n")
        File.chmod(locked, 0o000)

        json = parse(tools.find(name: ["*.cr"]))

        json["ok"].as_bool.should be_true
        json["errors"].as_a.size.should be > 0

        File.chmod(locked, 0o755)
      end
    end
  end

  describe "schemas" do
    it "ships valid JSON for each tool" do
      find = JSON.parse(FsUtils::Tools::FIND_SCHEMA)
      find["name"].as_s.should eq "find_files"
      find["input_schema"]["properties"]["name"]["type"].as_s.should eq "array"

      grep = JSON.parse(FsUtils::Tools::GREP_SCHEMA)
      grep["name"].as_s.should eq "search_file_contents"
      grep["input_schema"]["required"].as_a.map(&.as_s).should eq ["pattern"]
    end
  end
end
