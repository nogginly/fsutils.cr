require "../../spec_helper"

# Every case here resolves either a literal address or a name in /etc/hosts,
# so the suite never needs the network. Cases about the lists set
# allow_private_hosts so that no resolution happens at all.
private def policy(&)
  FsUtils::Web::HostPolicy.new do |settings|
    settings.allow_private_hosts = true
    yield settings
  end
end

private def check(policy, url : String) : Nil
  policy.check!(URI.parse(url))
end

describe FsUtils::Web::HostPolicy do
  describe "the lists" do
    it "permits any host when there is no allowlist" do
      check(policy { }, "https://example.com/page")
    end

    it "permits a host on the allowlist, and its subdomains" do
      guard = policy { |settings| settings.allowed_hosts = ["example.com"] }

      check(guard, "https://example.com/page")
      check(guard, "https://docs.example.com/page")
    end

    it "refuses a host that merely ends with an allowed name" do
      guard = policy { |settings| settings.allowed_hosts = ["example.com"] }

      expect_raises(FsUtils::HostNotAllowedError, /notexample\.com/) do
        check(guard, "https://notexample.com/page")
      end
    end

    it "refuses a denied host even when it is also allowed" do
      guard = policy do |settings|
        settings.allowed_hosts = ["example.com"]
        settings.denied_hosts = ["private.example.com"]
      end

      check(guard, "https://example.com/page")
      expect_raises(FsUtils::HostNotAllowedError) do
        check(guard, "https://private.example.com/page")
      end
    end

    # An empty list is a list naming nothing. The model cannot fix it by
    # picking a different URL, so it is told to stop rather than to retry.
    it "permits nothing under an empty allowlist, and says so" do
      guard = policy { |settings| settings.allowed_hosts = [] of String }

      error = expect_raises(FsUtils::HostNotAllowedError, /no hosts at all/) do
        check(guard, "https://example.com/page")
      end
      error.suggestion.to_s.should contain "Do not retry"
      error.code.should eq FsUtils::ErrorCode::HOST_NOT_ALLOWED
    end

    it "suggests another site when one host is refused" do
      guard = policy { |settings| settings.allowed_hosts = ["example.com"] }

      error = expect_raises(FsUtils::HostNotAllowedError) do
        check(guard, "https://elsewhere.test/page")
      end
      error.suggestion.to_s.should_not contain "Do not retry"
    end
  end

  describe "resolve, then compare" do
    it "refuses a literal loopback address" do
      expect_raises(FsUtils::HostNotAllowedError, /private network/) do
        check(FsUtils::Web::HostPolicy.new, "http://127.0.0.1:8080/admin")
      end
    end

    it "refuses a name that resolves to loopback" do
      expect_raises(FsUtils::HostNotAllowedError) do
        check(FsUtils::Web::HostPolicy.new, "http://localhost:8080/admin")
      end
    end

    it "refuses IPv6 loopback" do
      expect_raises(FsUtils::HostNotAllowedError) do
        check(FsUtils::Web::HostPolicy.new, "http://[::1]/admin")
      end
    end

    it "refuses the cloud metadata endpoint" do
      expect_raises(FsUtils::HostNotAllowedError, /169\.254\.169\.254/) do
        check(FsUtils::Web::HostPolicy.new, "http://169.254.169.254/latest/meta-data/")
      end
    end

    it "refuses a private range" do
      expect_raises(FsUtils::HostNotAllowedError) do
        check(FsUtils::Web::HostPolicy.new, "http://192.168.1.1/")
      end
    end

    it "permits what the operator has allowed" do
      guard = FsUtils::Web::HostPolicy.new { |settings| settings.allow_private_hosts = true }

      check(guard, "http://127.0.0.1:8080/admin")
    end
  end

  it "refuses a URL naming no host" do
    expect_raises(FsUtils::HostNotAllowedError, /no host/) do
      check(FsUtils::Web::HostPolicy.new, "/relative/path")
    end
  end

  describe FsUtils::Web::HostPolicy::Settings do
    it "refuses a pattern carrying a scheme or path" do
      expect_raises(ArgumentError, /scheme or path/) do
        FsUtils::Web::HostPolicy.new { |settings| settings.denied_hosts = ["https://example.com"] }
      end
    end

    it "refuses a blank pattern" do
      expect_raises(ArgumentError, /blank/) do
        FsUtils::Web::HostPolicy.new { |settings| settings.allowed_hosts = [" "] }
      end
    end
  end
end
