require "../spec_helper"

describe FsUtils::Error do
  it "reports no code from the base class" do
    # A bare Error means "the layer above decides", which the tool layer reads
    # as an invalid argument.
    FsUtils::Error.new("something went wrong").code.should be_nil
  end

  it "carries an optional suggestion" do
    error = FsUtils::Error.new("bad", "try this instead")
    error.message.should eq "bad"
    error.suggestion.should eq "try this instead"
  end

  it "omits the suggestion when there is nothing useful to say" do
    FsUtils::Error.new("bad").suggestion.should be_nil
  end

  describe "typed subclasses" do
    it "each reports its own code" do
      {
        FsUtils::NotFoundError           => FsUtils::ErrorCode::NOT_FOUND,
        FsUtils::IsDirectoryError        => FsUtils::ErrorCode::IS_DIRECTORY,
        FsUtils::BinaryContentError      => FsUtils::ErrorCode::BINARY_CONTENT,
        FsUtils::NotUtf8Error            => FsUtils::ErrorCode::NOT_UTF8,
        FsUtils::PermissionDeniedError   => FsUtils::ErrorCode::PERMISSION_DENIED,
        FsUtils::TooLargeError           => FsUtils::ErrorCode::TOO_LARGE,
        FsUtils::ContentTooLargeError    => FsUtils::ErrorCode::CONTENT_TOO_LARGE,
        FsUtils::ParentNotDirectoryError => FsUtils::ErrorCode::PARENT_NOT_DIRECTORY,
        FsUtils::WriteFailedError        => FsUtils::ErrorCode::WRITE_FAILED,
        FsUtils::InvalidPatternError     => FsUtils::ErrorCode::INVALID_PATTERN,
        FsUtils::OutsideSandboxError     => FsUtils::ErrorCode::OUTSIDE_SANDBOX,
      }.each do |klass, code|
        klass.new("message").code.should eq code
      end
    end

    it "is rescuable as FsUtils::Error" do
      rescued = begin
        raise FsUtils::NotFoundError.new("gone")
      rescue ex : FsUtils::Error
        ex
      end

      rescued.code.should eq FsUtils::ErrorCode::NOT_FOUND
    end

    it "puts the sandbox escape in the same family" do
      # So no `case` has to remember to test it before FsUtils::Error.
      FsUtils::Tools::Sandbox::Escape.new("out").code
        .should eq FsUtils::ErrorCode::OUTSIDE_SANDBOX
    end
  end

  it "is aliased inside Tools so tool-layer code reads unchanged" do
    FsUtils::Tools::ErrorCode::NOT_FOUND.should eq FsUtils::ErrorCode::NOT_FOUND
  end
end
