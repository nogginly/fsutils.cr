module FsUtils
  # The vocabulary both layers speak about failure.
  #
  # These live in `FsUtils` rather than `Tools` because the helpers are what
  # detect a failure and therefore what know its kind. Having a helper name a
  # constant belonging to the layer above it would invert the dependency; the
  # tool layer is free to map these to whatever an agent should see.
  module ErrorCode
    # Searching
    OUTSIDE_SANDBOX  = "path_outside_sandbox"
    NOT_FOUND        = "path_not_found"
    INVALID_PATTERN  = "invalid_pattern"
    INVALID_ARGUMENT = "invalid_argument"

    # Reading
    IS_DIRECTORY      = "is_directory"
    BINARY_CONTENT    = "binary_content"
    NOT_UTF8          = "not_utf8"
    RANGE_TOO_LARGE   = "range_too_large"
    PERMISSION_DENIED = "permission_denied"
    TOO_LARGE         = "too_large"

    # Replacing
    NO_MATCH          = "no_match"
    NOT_UNIQUE        = "not_unique"
    STRINGS_IDENTICAL = "strings_identical"
    EMPTY_OLD_STRING  = "empty_old_string"

    # Writing
    FILE_EXISTS          = "file_exists"
    PARENT_NOT_DIRECTORY = "parent_not_directory"
    CONTENT_TOO_LARGE    = "content_too_large"
    WRITE_FAILED         = "write_failed"
  end

  # Raised for caller error that a helper cannot recover from: a bad pattern,
  # a missing file. Filesystem trouble encountered *during* a walk is collected
  # into `Report#errors` instead.
  #
  # `suggestion` is optional prose naming the way out, carried here so that
  # whoever detects the problem — which knows what the valid values were —
  # writes the advice.
  #
  # `code` is the failure's kind. Subclasses answer it; the base class does
  # not, and a bare `Error` means "the layer above should decide". This
  # replaces an earlier arrangement where the tool layer guessed the kind by
  # searching the message for words like "binary", which worked until someone
  # rephrased a message.
  class Error < Exception
    getter suggestion : String?

    def initialize(message : String, @suggestion : String? = nil)
      super(message)
    end

    def code : String?
      nil
    end
  end

  macro def_error(name, code)
    class {{ name.id }} < Error
      def code : String?
        {{ code.id }}
      end
    end
  end

  def_error NotFoundError, ErrorCode::NOT_FOUND
  def_error IsDirectoryError, ErrorCode::IS_DIRECTORY
  def_error BinaryContentError, ErrorCode::BINARY_CONTENT
  def_error NotUtf8Error, ErrorCode::NOT_UTF8
  def_error PermissionDeniedError, ErrorCode::PERMISSION_DENIED
  def_error TooLargeError, ErrorCode::TOO_LARGE
  def_error ContentTooLargeError, ErrorCode::CONTENT_TOO_LARGE
  def_error ParentNotDirectoryError, ErrorCode::PARENT_NOT_DIRECTORY
  def_error WriteFailedError, ErrorCode::WRITE_FAILED
  def_error InvalidPatternError, ErrorCode::INVALID_PATTERN
  def_error OutsideSandboxError, ErrorCode::OUTSIDE_SANDBOX
  def_error NoMatchError, ErrorCode::NO_MATCH
  def_error NotUniqueError, ErrorCode::NOT_UNIQUE
  def_error StringsIdenticalError, ErrorCode::STRINGS_IDENTICAL
  def_error EmptyOldStringError, ErrorCode::EMPTY_OLD_STRING
end
