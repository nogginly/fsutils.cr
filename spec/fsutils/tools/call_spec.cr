require "../../spec_helper"

private def with_tools(&)
  root = ::File.join(Dir.tempdir, "fs_utils_call_#{Random.rand(1 << 30)}")
  begin
    Dir.mkdir_p(::File.join(root, "src"))
    ::File.write(::File.join(root, "src", "a.cr"), "one hit\ntwo\nthree hit\n")
    ::File.write(::File.join(root, "src", "b.cr"), "nothing\n")
    yield FsUtils::Tools.new(root), root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def call(tools, name, arguments = "{}")
  JSON.parse(tools.call(name, JSON.parse(arguments)))
end

describe "FsUtils::Tools#call" do
  describe "dispatch" do
    it "runs each tool under its published name" do
      with_tools do |tools, _|
        call(tools, "find_files", %({"name": ["*.cr"]}))["ok"].as_bool.should be_true
        call(tools, "search_file_contents", %({"pattern": "hit"}))["ok"].as_bool.should be_true
        call(tools, "read_text_file", %({"path": "src/a.cr"}))["ok"].as_bool.should be_true
        call(tools, "write_text_file", %({"path": "n.txt", "content": "x"}))["ok"].as_bool.should be_true
        call(tools, "text_replace",
          %({"path": "src/b.cr", "old_string": "nothing", "new_string": "something"}))["ok"]
          .as_bool.should be_true
      end
    end

    it "returns what the typed method would have" do
      with_tools do |tools, _|
        tools.call("read_text_file", JSON.parse(%({"path": "src/a.cr"})))
          .should eq tools.read(path: "src/a.cr").to_json
      end
    end

    it "accepts an empty object and a null for a tool with no required arguments" do
      with_tools do |tools, _|
        call(tools, "find_files")["ok"].as_bool.should be_true
        call(tools, "find_files", "null")["ok"].as_bool.should be_true
      end
    end
  end

  describe "an unknown tool name" do
    # The host chose what to register, so the host is who can act on this.
    # A model can invent a name, so this is reachable, not theoretical.
    it "raises rather than answering the model" do
      with_tools do |tools, _|
        expect_raises(ArgumentError, /unknown tool: fs_read_text_file/) do
          tools.call("fs_read_text_file", JSON.parse(%({"path": "src/a.cr"})))
        end
      end
    end
  end

  describe "arguments the model can fix" do
    it "refuses a parameter the tool does not accept, and lists the ones it does" do
      with_tools do |tools, _|
        json = call(tools, "read_text_file", %({"path": "src/a.cr", "max_bytes": 100}))

        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq "invalid_argument"
        json["error"]["message"].as_s.should contain "max_bytes"
        json["error"]["suggestion"].as_s.should contain "line_numbers"
      end
    end

    it "refuses a wrong type rather than coercing it" do
      with_tools do |tools, _|
        json = call(tools, "find_files", %({"max_matches": "200"}))

        json["ok"].as_bool.should be_false
        json["error"]["message"].as_s.should contain "must be an integer"
      end
    end

    it "refuses an array holding a non-string" do
      with_tools do |tools, _|
        json = call(tools, "find_files", %({"name": ["*.cr", 7]}))
        json["error"]["message"].as_s.should contain "array of strings"
      end
    end

    it "refuses arguments that are not an object" do
      with_tools do |tools, _|
        json = call(tools, "find_files", %(["*.cr"]))
        json["error"]["message"].as_s.should contain "must be a JSON object"
      end
    end

    it "reports a missing required argument" do
      with_tools do |tools, _|
        json = call(tools, "read_text_file")

        json["ok"].as_bool.should be_false
        json["error"]["message"].as_s.should contain "requires path"
      end
    end

    it "treats an explicit null as absent" do
      with_tools do |tools, _|
        call(tools, "find_files", %({"max_matches": null}))["ok"].as_bool.should be_true
        call(tools, "read_text_file", %({"path": null}))["error"]["message"]
          .as_s.should contain "requires path"
      end
    end
  end

  describe "argument passing" do
    it "honours an explicit false over the tool's default" do
      with_tools do |tools, _|
        json = call(tools, "read_text_file", %({"path": "src/a.cr", "line_numbers": false}))
        json["content"].as_s.should eq "one hit\ntwo\nthree hit\n"
      end
    end

    it "carries every argument through" do
      with_tools do |tools, _|
        json = call(tools, "search_file_contents", %({
          "pattern": "HIT",
          "paths": ["src"],
          "mode": "paths",
          "ignore_case": true,
          "types": ["cr"],
          "max_matches": 5,
          "max_depth": 4,
          "include_hidden": true,
          "timeout_seconds": 5.0
        }))

        json["ok"].as_bool.should be_true
        json["results"].as_a.size.should eq 1
      end
    end

    it "confines paths exactly as the typed method does" do
      with_tools do |tools, _|
        json = call(tools, "read_text_file", %({"path": "../outside.txt"}))

        json["ok"].as_bool.should be_false
        json["error"]["code"].as_s.should eq FsUtils::ErrorCode::OUTSIDE_SANDBOX
      end
    end
  end

  describe "accepted arguments" do
    # Read from the published schemas rather than kept by hand, so a parameter
    # added to a schema is accepted without anyone remembering to.
    it "matches each tool's schema exactly" do
      FsUtils::Tools::DEFINITIONS.each do |tool|
        declared = JSON.parse(tool.schema)["properties"].as_h.keys
        FsUtils::Tools::Arguments::ACCEPTED[tool.name].should eq declared
      end
    end
  end
end
