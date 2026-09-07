module FsUtils
  # Writes a text file in full, atomically.
  #
  # ```
  # result = FsUtils::Writer.new("src/out.cr", "puts 1\n").write
  # result.created # => true
  # ```
  #
  # **This helper will happily replace anything you point it at.** The guard
  # that asks whether an overwrite was intended is a policy, and policy lives
  # in `Tools`. A Crystal caller writing a file it just composed does not need
  # to be asked twice; a language model does.
  #
  # Content is written exactly as supplied: no trailing newline appended, no
  # line endings normalised, no whitespace trimmed. Anything the tool adds
  # makes its output differ from its input, which is a small lie told in the
  # one place precision matters.
  class Writer
    MAX_CONTENT_BYTES = 10_485_760

    record Result,
      created : Bool,
      bytes_written : Int64,
      lines : Int32,
      parents_created : Array(String)

    def initialize(
      @path : String,
      @content : String,
      @max_content_bytes : Int64 = MAX_CONTENT_BYTES.to_i64,
    )
      raise ArgumentError.new("path must not contain null bytes") if @path.includes?('\0')

      if @content.bytesize > @max_content_bytes
        raise FsUtils::Error.new(
          "content is #{@content.bytesize} bytes, over the #{@max_content_bytes} byte ceiling",
          "Write less in one call, or split the content across files.")
      end
    end

    def write : Result
      check_destination
      created = !::File.exists?(@path)
      parents = create_parents

      write_atomically

      info = ::File.info(@path)
      Result.new(
        created: created,
        bytes_written: info.size,
        lines: count_lines,
        parents_created: parents,
      )
    end

    # ------------------------------------------------------------------ #

    private def check_destination : Nil
      return unless ::File.exists?(@path)

      if ::File.directory?(@path)
        raise FsUtils::Error.new(
          "#{@path} is a directory, not a file",
          "Name a file inside it, or choose a different path.")
      end
    end

    # Creating a directory destroys nothing, so this needs no guard — the worst
    # outcome is an empty directory in the wrong place, which is visible and
    # trivially removed. Reporting what was made catches the failure a flag
    # would have caught, one turn later instead of ten.
    private def create_parents : Array(String)
      made = [] of String
      parent = ::File.dirname(@path)
      missing = [] of String
      current = parent

      while !::File.exists?(current)
        missing << current
        upper = ::File.dirname(current)
        break if upper == current
        current = upper
      end

      unless ::File.directory?(current)
        raise FsUtils::Error.new(
          "#{current} exists but is not a directory",
          "A path segment is a file. Choose a different path.")
      end

      missing.reverse_each do |dir|
        Dir.mkdir(dir)
        made << dir
      end

      made
    end

    # Temp file in the destination directory, fsync, then rename. A failed
    # write leaves the original intact rather than truncated, which matters
    # most in exactly the case the overwrite guard is protecting.
    private def write_atomically : Nil
      dir = ::File.dirname(@path)
      temp = ::File.join(dir, ".#{::File.basename(@path)}.#{Random.rand(UInt32)}.tmp")

      begin
        ::File.open(temp, "w") do |file|
          file.print(@content)
          file.flush
          file.fsync
        end

        inherit_permissions(temp)
        ::File.rename(temp, @path)
      rescue ex
        ::File.delete?(temp)
        raise translate(ex)
      end
    end

    private def inherit_permissions(temp : String) : Nil
      return unless ::File.exists?(@path)
      ::File.chmod(temp, ::File.info(@path).permissions)
    rescue
      # A destination we cannot stat is one the rename is about to fail on
      # anyway; let that report the real problem.
    end

    private def translate(ex : Exception) : Exception
      case ex
      when ::File::AccessDeniedError
        FsUtils::Error.new("#{@path} is not writable")
      when IO::Error
        FsUtils::Error.new(
          "write to #{@path} failed: #{ex.message}",
          "The file was not modified. Check available space and permissions.")
      else
        ex
      end
    end

    # Counted from disk rather than from the input string, so a truncated or
    # mangled write is visible in the result.
    private def count_lines : Int32
      count = 0
      ::File.open(@path, "r") { |file| file.each_line { count += 1 } }
      count
    end
  end
end
