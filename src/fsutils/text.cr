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
  end
end
