require "../../spec_helper"
require "http/server"

# The whole suite runs against a server on loopback, so nothing here touches
# the network. That means every case has to allow private hosts -- which is
# itself worth knowing: without it, none of this would be reachable.
private def with_server(&)
  server = HTTP::Server.new do |context|
    respond(context)
  end
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
  case path = context.request.path
  when "/small"
    response.content_type = "text/html; charset=utf-8"
    response.print "<html><body><h1>Small</h1></body></html>"
  when "/big"
    response.content_type = "text/html"
    response.print "<html><body>#{"x" * 64_000}</body></html>"
  when "/md"
    response.content_type = "text/markdown; charset=utf-8"
    response.print "# Served\n\nAlready Markdown.\n"
  when "/plain"
    response.content_type = "text/plain"
    response.print "not html"
  when "/zip"
    response.content_type = "application/zip"
    response.print "PK"
  when "/echo-accept"
    response.content_type = "text/html"
    response.print "<html><body>#{context.request.headers["Accept"]?}</body></html>"
  when "/untyped"
    response.print "<html><body>no content type</body></html>"
  when "/missing"
    response.status_code = 404
    response.content_type = "text/html"
    response.print "<html><body>gone</body></html>"
  when "/redirect"
    response.status_code = 302
    response.headers["Location"] = "/small"
  when "/loop"
    response.status_code = 302
    response.headers["Location"] = "/loop"
  else
    response.status_code = 404
    response.print "unknown #{path}"
  end
end

private def fetcher(max_page_bytes : Int64 = 1_048_576i64, max_redirects : Int32 = 5)
  FsUtils::Web::Fetcher.new do |settings|
    settings.host_policy.allow_private_hosts = true
    settings.max_page_bytes = max_page_bytes
    settings.max_redirects = max_redirects
  end
end

describe FsUtils::Web::Fetcher do
  it "fetches a page" do
    with_server do |base|
      page = fetcher.fetch("#{base}/small")

      page.status.should eq 200
      page.body.should contain "<h1>Small</h1>"
      page.content_type.should eq "text/html"
      page.bytes.should eq page.body.bytesize
    end
  end

  # A redirect changes what was actually read, and the converter resolves
  # relative links against it.
  it "reports the address the content came from, not the one asked for" do
    with_server do |base|
      page = fetcher.fetch("#{base}/redirect")

      page.url.should end_with "/small"
      page.body.should contain "Small"
    end
  end

  it "gives up on a redirect loop" do
    with_server do |base|
      error = expect_raises(FsUtils::FetchFailedError, /redirected more than 2 times/) do
        fetcher(max_redirects: 2).fetch("#{base}/loop")
      end
      error.code.should eq FsUtils::ErrorCode::FETCH_FAILED
    end
  end

  # Gate 1: counted from the read, since Content-Length is absent under
  # chunked encoding and understates a compressed body.
  it "stops reading a body past the cap" do
    with_server do |base|
      error = expect_raises(FsUtils::TooLargeError, /larger than 1024 bytes/) do
        fetcher(max_page_bytes: 1_024i64).fetch("#{base}/big")
      end
      error.code.should eq FsUtils::ErrorCode::TOO_LARGE
    end
  end

  it "reads a body under the cap" do
    with_server do |base|
      fetcher(max_page_bytes: 1_048_576i64).fetch("#{base}/big").bytes.should be > 64_000
    end
  end

  # Documentation sites increasingly answer the Accept header this way. What
  # to do about it belongs to the caller; this class only reports it.
  it "reports the content type it was given" do
    with_server do |base|
      page = fetcher.fetch("#{base}/md")

      page.content_type.should eq "text/markdown"
      page.body.should contain "# Served"
      fetcher.fetch("#{base}/small").content_type.should eq "text/html"
    end
  end

  it "reads a text type it was not specifically told about" do
    with_server do |base|
      fetcher.fetch("#{base}/plain").body.should contain "not html"
    end
  end

  it "refuses a type outside the accepted list" do
    with_server do |base|
      guard = FsUtils::Web::Fetcher.new do |settings|
        settings.host_policy.allow_private_hosts = true
        settings.accepted_types = ["text/html"]
      end

      expect_raises(FsUtils::UnsupportedContentTypeError, /text\/plain/) do
        guard.fetch("#{base}/plain")
      end
    end
  end

  it "asks for Markdown ahead of HTML" do
    with_server do |base|
      fetcher.fetch("#{base}/echo-accept").body.should contain "text/markdown"
    end
  end

  it "refuses content that is not text at all" do
    with_server do |base|
      error = expect_raises(FsUtils::UnsupportedContentTypeError, /application\/zip/) do
        fetcher.fetch("#{base}/zip")
      end
      error.code.should eq FsUtils::ErrorCode::UNSUPPORTED_CONTENT_TYPE
    end
  end

  # An absent type is not a wrong type, and servers omit it.
  it "accepts a response with no content type" do
    with_server do |base|
      fetcher.fetch("#{base}/untyped").body.should contain "no content type"
    end
  end

  it "reports an error status rather than its body" do
    with_server do |base|
      error = expect_raises(FsUtils::HttpError, /404/) do
        fetcher.fetch("#{base}/missing")
      end
      error.code.should eq FsUtils::ErrorCode::HTTP_ERROR
    end
  end

  it "refuses a scheme it cannot fetch" do
    expect_raises(FsUtils::HostNotAllowedError, /not an http or https URL/) do
      fetcher.fetch("file:///etc/passwd")
    end
  end

  # The policy runs before the request, so this never reaches the network.
  it "refuses a host the policy denies" do
    guard = FsUtils::Web::Fetcher.new { |settings| settings.host_policy.allowed_hosts = [] of String }

    expect_raises(FsUtils::HostNotAllowedError, /no hosts at all/) do
      guard.fetch("https://example.com/page")
    end
  end

  describe FsUtils::Web::Fetcher::Settings do
    it "refuses a cap of nothing" do
      expect_raises(ArgumentError, /max_page_bytes/) do
        FsUtils::Web::Fetcher.new { |settings| settings.max_page_bytes = 0i64 }
      end
    end

    it "refuses a timeout of nothing" do
      expect_raises(ArgumentError, /timeout/) do
        FsUtils::Web::Fetcher.new { |settings| settings.timeout = 0.seconds }
      end
    end

    it "carries the host policy's own validation" do
      expect_raises(ArgumentError, /scheme or path/) do
        FsUtils::Web::Fetcher.new { |settings| settings.host_policy.denied_hosts = ["http://example.com"] }
      end
    end
  end
end
