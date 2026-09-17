require "../../spec_helper"

private def with_tree(&)
  root = ::File.join(Dir.tempdir, "fs_utils_config_#{Random.rand(1 << 30)}")
  begin
    Dir.mkdir_p(::File.join(root, "sub"))
    ::File.write(::File.join(root, "a.txt"), (1..40).map { |i| "line #{i} hit" }.join("\n"))
    ::File.write(::File.join(root, "b.txt"), "hit\n")
    ::File.write(::File.join(root, "sub", "c.txt"), "hit\n")
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def parse(response)
  JSON.parse(response.to_json)
end

describe FsUtils::Tools::Config do
  describe "defaults" do
    it "constructs with every section present" do
      config = FsUtils::Tools::Config.new
      config.find.max_matches.should eq 200
      config.grep.max_depth.should eq 25
      config.read.default_limit.should eq FsUtils::Reader::DEFAULT_LIMIT
      config.max_output_bytes.should eq FsUtils::Tools::DEFAULT_MAX_OUTPUT_BYTES
      config.reproducible?.should be_false
    end
  end

  describe "from YAML" do
    it "reads a document naming one field and leaves the rest standing" do
      config = FsUtils::Tools::Config.from_yaml(<<-YAML)
        write:
          max_content_bytes: 1024
        YAML

      config.write.max_content_bytes.should eq 1024_i64
      config.read.max_bytes.should eq FsUtils::Reader::DEFAULT_MAX_BYTES
      config.find.max_matches.should eq 200
    end

    it "reads every section" do
      config = FsUtils::Tools::Config.from_yaml(<<-YAML)
        max_output_bytes: 4096
        reproducible: true
        find:
          max_matches: 5
          include_hidden: true
        grep:
          max_matches: 7
          max_matches_per_file: 2
        read:
          default_limit: 3
        replace:
          context_lines: 0
        YAML

      config.max_output_bytes.should eq 4096
      config.reproducible?.should be_true
      config.find.max_matches.should eq 5
      config.find.include_hidden?.should be_true
      config.grep.max_matches_per_file.should eq 2
      config.read.default_limit.should eq 3
      config.replace.context_lines.should eq 0
    end

    it "round-trips through JSON" do
      config = FsUtils::Tools::Config.new
      config.grep.max_line_length = 42
      FsUtils::Tools::Config.from_json(config.to_json).grep.max_line_length.should eq 42
    end
  end

  describe "#to_settings" do
    it "converts seconds to a span" do
      config = FsUtils::Tools::Config.new
      config.find.timeout_seconds = 2.5
      config.find.to_settings.timeout.should eq 2.5.seconds
    end

    # Every field of every helper's Settings must be reachable from
    # configuration. A field added to one side and forgotten on the other
    # fails here rather than silently ignoring a host's YAML.
    it "carries every find field through" do
      config = FsUtils::Tools::Config::Find.new
      config.max_matches = 1
      config.max_matches_per_dir = 2
      config.max_entries_scanned = 3
      config.max_depth = 4
      config.timeout_seconds = 5.0
      config.follow_symlinks = true
      config.include_hidden = true
      config.skip_dirs = ["nope"]

      settings = config.to_settings
      settings.max_matches.should eq 1
      settings.max_matches_per_dir.should eq 2
      settings.max_entries_scanned.should eq 3
      settings.max_depth.should eq 4
      settings.timeout.should eq 5.seconds
      settings.follow_symlinks?.should be_true
      settings.include_hidden?.should be_true
      settings.skip_dirs.should eq ["nope"]
    end

    it "carries every grep field through" do
      config = FsUtils::Tools::Config::Grep.new
      config.max_matches = 1
      config.max_matches_per_file = 2
      config.max_matches_per_dir = 3
      config.max_entries_scanned = 4
      config.max_depth = 5
      config.max_file_bytes = 6_i64
      config.max_line_length = 7
      config.timeout_seconds = 8.0
      config.follow_symlinks = true
      config.include_hidden = true
      config.skip_dirs = ["nope"]

      settings = config.to_settings
      settings.max_matches.should eq 1
      settings.max_matches_per_file.should eq 2
      settings.max_matches_per_dir.should eq 3
      settings.max_entries_scanned.should eq 4
      settings.max_depth.should eq 5
      settings.max_file_bytes.should eq 6_i64
      settings.max_line_length.should eq 7
      settings.timeout.should eq 8.seconds
      settings.follow_symlinks?.should be_true
      settings.include_hidden?.should be_true
      settings.skip_dirs.should eq ["nope"]
    end

    it "carries every text field through" do
      read = FsUtils::Tools::Config::Read.new
      read.max_bytes = 1
      read.max_line_length = 2
      read.max_file_bytes = 3_i64

      read.to_settings.max_bytes.should eq 1
      read.to_settings.max_line_length.should eq 2
      read.to_settings.max_file_bytes.should eq 3_i64

      write = FsUtils::Tools::Config::Write.new
      write.max_content_bytes = 4_i64
      write.to_settings.max_content_bytes.should eq 4_i64

      replace = FsUtils::Tools::Config::Replace.new
      replace.context_lines = 5
      replace.max_hunks = 6
      replace.max_file_bytes = 7_i64

      replace.to_settings.context_lines.should eq 5
      replace.to_settings.max_hunks.should eq 6
      replace.to_settings.max_file_bytes.should eq 7_i64
    end
  end

  describe "validation" do
    it "raises at construction rather than on a call" do
      config = FsUtils::Tools::Config.new
      config.replace.max_hunks = 0

      expect_raises(ArgumentError, /max_hunks/) do
        FsUtils::Tools.new(Dir.tempdir, config)
      end
    end

    it "rejects a non-positive output budget" do
      config = FsUtils::Tools::Config.new
      config.max_output_bytes = 0

      expect_raises(ArgumentError, /max_output_bytes/) do
        FsUtils::Tools.new(Dir.tempdir, config)
      end
    end
  end

  describe "configured limits reach the tools" do
    it "bounds find" do
      with_tree do |root|
        config = FsUtils::Tools::Config.new
        config.find.max_matches = 1

        json = parse(FsUtils::Tools.new(root, config).find(name: ["*.txt"]))
        json["results"].as_a.size.should eq 1
        json["truncated"].as_bool.should be_true
      end
    end

    it "bounds grep, and a caller argument still wins" do
      with_tree do |root|
        config = FsUtils::Tools::Config.new
        config.grep.max_matches = 1
        tools = FsUtils::Tools.new(root, config)

        parse(tools.grep(pattern: "hit"))["results"].as_a.size.should eq 1
        parse(tools.grep(pattern: "hit", max_matches: 3))["results"].as_a.size.should eq 3
      end
    end

    it "bounds the default read window" do
      with_tree do |root|
        config = FsUtils::Tools::Config.new
        config.read.default_limit = 2

        json = parse(FsUtils::Tools.new(root, config).read(path: "a.txt"))
        json["range"]["first_line"].as_i.should eq 1
        json["range"]["last_line"].as_i.should eq 2
        json["truncated"].as_bool.should be_true
      end
    end

    it "bounds a write, and says so in the error" do
      with_tree do |root|
        config = FsUtils::Tools::Config.new
        config.write.max_content_bytes = 4_i64

        json = parse(FsUtils::Tools.new(root, config).write(path: "new.txt", content: "far too long"))
        json["ok"].as_bool.should be_false
        json["error"]["message"].as_s.should contain "4 byte ceiling"
      end
    end

    it "bounds the context a replacement returns" do
      with_tree do |root|
        config = FsUtils::Tools::Config.new
        config.replace.context_lines = 0

        json = parse(FsUtils::Tools.new(root, config).text_replace(
          path: "a.txt", old_string: "line 5 hit", new_string: "line 5 miss"))

        before = json["hunks"].as_a.first["before"].as_s
        before.should contain "line 5 hit"
        before.should_not contain "line 4"
        json["hunks"].as_a.first["start_line"].as_i.should eq 5
      end
    end
  end
end
