require "../../spec_helper"
require "http/server"

private def with_server(&)
  server = HTTP::Server.new { |context| respond(context) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield

  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

private def respond(context : HTTP::Server::Context) : Nil
  response = context.response
  response.content_type = "text/html"

  case context.request.path
  when "/small"
    response.print "<html><body><main><h1>Small</h1><p>A short page.</p></main></body></html>"
  when "/long"
    response.print long_page
  when "/titled"
    response.print "<html><head><title>A &amp; B: the page</title></head><body><p>Body.</p></body></html>"
  when "/md"
    response.content_type = "text/markdown"
    response.print "# Served\n\nAlready Markdown, with a [link](/other).\n"
  when "/bigmd"
    response.content_type = "text/markdown"
    response.print String.build { |io| 8.times { |index| io << "## Part " << index << "\n\n" << ("word " * 200) << "\n\n" } }
  when "/plain"
    response.content_type = "text/plain"
    response.print "not html"
  else
    response.status_code = 404
    response.print "<html><body>gone</body></html>"
  end
end

private def long_page : String
  String.build do |io|
    io << "<html><head><title>Long</title></head><body><main>"
    io << "<h1>Long</h1><p>Opening.</p>"
    6.times do |index|
      io << "<h2>Section " << index << "</h2><p>" << ("word " * 200) << "</p>"
    end
    io << "</main></body></html>"
  end
end

private def with_tools(max_output_bytes : Int32 = 32_000, &)
  root = ::File.join(Dir.tempdir, "fsutils-fetch-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(root)

  config = FsUtils::Tools::Config.new
  config.max_output_bytes = max_output_bytes
  config.fetch.allow_private_hosts = true

  begin
    yield FsUtils::Tools.new(root, config), root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "FsUtils::Tools#fetch" do
  it "returns a short page inline" do
    with_server do |base|
      with_tools do |tools, root|
        response = tools.fetch("#{base}/small")

        response.ok?.should be_true
        response.status.should eq 200
        response.content.to_s.should contain "# Small"
        response.path.should be_nil
        Dir.exists?(::File.join(root, FsUtils::Tools::Scratch::DEFAULT_DIR)).should be_false
      end
    end
  end

  it "reads the title from the page's head, which the converter drops" do
    with_server do |base|
      with_tools do |tools, _|
        tools.fetch("#{base}/titled").title.should eq "A & B: the page"
      end
    end
  end

  describe "a page too long to inline" do
    it "writes it to the scratch area and describes it" do
      with_server do |base|
        with_tools(max_output_bytes: 500) do |tools, root|
          response = tools.fetch("#{base}/long")

          response.ok?.should be_true
          response.content.should be_nil
          path = response.path.to_s
          path.should start_with FsUtils::Tools::Scratch::DEFAULT_DIR
          ::File.exists?(::File.join(root, path)).should be_true
          response.excerpt.to_s.should contain "# Long"
        end
      end
    end

    # The whole point of the table of contents: its numbers are what
    # read_text_file takes, against the file as it was actually written.
    it "indexes the file it wrote, front matter included" do
      with_server do |base|
        with_tools(max_output_bytes: 500) do |tools, root|
          response = tools.fetch("#{base}/long")
          toc = response.toc.not_nil!

          toc.map(&.title).first.should eq "Long"
          toc.map(&.level).should contain 2

          lines = ::File.read(::File.join(root, response.path.to_s)).lines
          lines[toc.first.start_line - 1].should eq "# Long"
          response.lines.should eq lines.size
        end
      end
    end

    it "opens the file with front matter naming where it came from" do
      with_server do |base|
        with_tools(max_output_bytes: 500) do |tools, root|
          response = tools.fetch("#{base}/long")

          document = ::File.read(::File.join(root, response.path.to_s))
          document.should start_with "---\n"
          document.should contain %(source: "#{base}/long")
        end
      end
    end

    # Otherwise a later search turns up the agent's own spilled pages.
    it "keeps the scratch area out of later searches" do
      with_server do |base|
        with_tools(max_output_bytes: 500) do |tools, _|
          tools.fetch("#{base}/long")

          found = tools.find(name: ["*.md"], include_hidden: true)
          (found.results.try(&.map(&.path)) || [] of String).should be_empty

          matched = tools.grep(pattern: "Section", include_hidden: true)
          (matched.results.try(&.size) || 0).should eq 0
        end
      end
    end
  end

  # A site that already speaks Markdown has done the work; the tool's job is
  # then to apply the same bounds to it, not to convert it twice.
  describe "a site that serves Markdown" do
    it "uses what it was given" do
      with_server do |base|
        with_tools do |tools, _|
          response = tools.fetch("#{base}/md")

          response.ok?.should be_true
          response.content.to_s.should contain "[link](/other)"
        end
      end
    end

    it "takes its title from the first top-level heading" do
      with_server do |base|
        with_tools do |tools, _|
          tools.fetch("#{base}/md").title.should eq "Served"
        end
      end
    end

    # Otherwise max_markdown_bytes would bound a converted page and nothing
    # at all for a served one.
    it "is bounded like a converted page" do
      with_server do |base|
        with_tools do |tools, root|
          config = FsUtils::Tools::Config.new
          config.fetch.allow_private_hosts = true
          config.fetch.max_markdown_bytes = 400_i64
          bounded = FsUtils::Tools.new(root, config)

          response = bounded.fetch("#{base}/bigmd")

          response.truncated.should be_true
          response.bytes.not_nil!.should be <= 400
          response.notice.to_s.should contain "block boundary"
        end
      end
    end
  end

  describe "failures a caller can act on" do
    it "answers rather than raises for content it cannot convert" do
      with_server do |base|
        with_tools do |tools, _|
          response = tools.fetch("#{base}/plain")

          response.ok?.should be_false
          response.error.try(&.code).should eq FsUtils::ErrorCode::UNSUPPORTED_CONTENT_TYPE
        end
      end
    end

    it "answers rather than raises for a missing page" do
      with_server do |base|
        with_tools do |tools, _|
          response = tools.fetch("#{base}/nowhere")

          response.ok?.should be_false
          response.error.try(&.code).should eq FsUtils::ErrorCode::HTTP_ERROR
        end
      end
    end

    it "answers rather than raises for a host it may not reach" do
      root = ::File.join(Dir.tempdir, "fsutils-fetch-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(root)

      begin
        response = FsUtils::Tools.new(root).fetch("http://127.0.0.1:1/page")

        response.ok?.should be_false
        response.error.try(&.code).should eq FsUtils::ErrorCode::HOST_NOT_ALLOWED
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  describe "by name" do
    it "dispatches and serialises" do
      with_server do |base|
        with_tools do |tools, _|
          response = tools.call(FsUtils::Tools::Names::FETCH,
            {"url" => JSON::Any.new("#{base}/small")})

          response.ok?.should be_true
          JSON.parse(response.to_json)["content"].as_s.should contain "# Small"
        end
      end
    end

    it "is published with the others" do
      FsUtils::Tools::Definitions.all.map(&.name).should contain FsUtils::Tools::Names::FETCH
    end
  end
end
