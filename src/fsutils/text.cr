module FsUtils
  # Primitives shared by anything that reads file content.
  #
  # `Grep` and the file-reading tools ask the same two questions — is this
  # binary, and is this line absurdly long — and answering them differently in
  # two places is how the answers drift apart.
  module Text
    # A NUL byte in the first block is the same heuristic `grep(1)` uses. It is
    # not proof, but the alternative is matching a regex against a JPEG and
    # emitting the result.
    SNIFF_BYTES = 8192

    def self.binary?(bytes : Bytes) : Bool
      bytes.includes?(0_u8)
    end

    # Reads a block from the current position and rewinds, so the caller can
    # scan the file afterwards.
    def self.binary?(io : IO::FileDescriptor) : Bool
      buffer = Bytes.new(SNIFF_BYTES)
      read = io.read(buffer)
      io.rewind
      return false if read == 0
      binary?(buffer[0, read])
    end

    # Returns the line cut to `max` characters, and how many characters were
    # dropped. Zero means it fitted.
    #
    # Counted in characters rather than bytes: the result is handed to a model
    # as text, and cutting mid-codepoint would produce something it cannot read.
    def self.clamp(line : String, max : Int32) : {String, Int32}
      size = line.size
      return {line, 0} if size <= max
      {line[0, max], size - max}
    end

    # Returns the text cut back to its last blank line.
    #
    # Markdown handed to a model has to end somewhere it can be read. Cutting
    # at an arbitrary offset can end inside a fenced code block or halfway
    # through a table row, which is worse than stopping earlier: the reader
    # cannot tell a truncated construct from a malformed one.
    def self.trim_to_block(text : String) : String
      boundary = text.rindex("\n\n")
      (boundary ? text[0, boundary] : text).strip
    end

    # Returns at most `max_bytes` of `text`, ending at a block boundary, and
    # whether anything was dropped.
    #
    # Bounded in bytes because the limit it serves is a byte budget, but never
    # cut mid-codepoint: the prefix walks back off any continuation byte
    # before the block boundary is looked for.
    def self.block_prefix(text : String, max_bytes : Int64) : {String, Bool}
      return {text, false} if text.bytesize <= max_bytes
      {trim_to_block(byte_prefix(text, max_bytes)), true}
    end

    private def self.byte_prefix(text : String, max_bytes : Int64) : String
      bytes = text.to_slice
      limit = max_bytes.clamp(0_i64, bytes.size.to_i64).to_i
      while limit > 0 && limit < bytes.size && (bytes[limit] & 0xC0) == 0x80
        limit -= 1
      end
      String.new(bytes[0, limit])
    end
  end
end
