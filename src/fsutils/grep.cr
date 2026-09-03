module FsUtils
  # A `grep`-alike with guard rails, intended to back an agent's `search_files`
  # tool. Matches are yielded as they are found; `run` returns a `Summary`.
  #
  # ```
  # summary = FsUtils::Grep.new("TODO", path: "src").run do |m|
  #   puts "#{m.relative_path}:#{m.line_number}: #{m.line}"
  # end
  # ```
  #
  # A single instance is not thread-safe and holds state for the duration of
  # `run`; create a new one per search.
  class Grep
    class Error < Exception; end

    DEFAULT_SKIP_DIRS = %w[.git .hg .svn node_modules lib vendor target build dist .cache]

    # Named glob sets, `rg --type` style. Unknown names raise `Error`.
    TYPES = {
      "crystal" => %w[*.cr *.ecr],
      "cr"      => %w[*.cr *.ecr],
      "ruby"    => %w[*.rb *.rake *.gemspec Rakefile Gemfile],
      "js"      => %w[*.js *.mjs *.cjs *.jsx],
      "ts"      => %w[*.ts *.tsx *.mts *.cts],
      "web"     => %w[*.html *.htm *.css *.scss *.svg],
      "py"      => %w[*.py *.pyi],
      "go"      => %w[*.go],
      "rust"    => %w[*.rs],
      "c"       => %w[*.c *.h],
      "cpp"     => %w[*.cc *.cpp *.cxx *.hh *.hpp *.hxx],
      "java"    => %w[*.java],
      "sh"      => %w[*.sh *.bash *.zsh],
      "sql"     => %w[*.sql],
      "md"      => %w[*.md *.markdown],
      "json"    => %w[*.json],
      "yaml"    => %w[*.yml *.yaml],
      "toml"    => %w[*.toml],
      "config"  => %w[*.json *.yml *.yaml *.toml *.ini *.env],
    }

    # What to yield.
    #
    # * `Lines` — one `Match` per matching line (the default).
    # * `Paths` — one `Match` per *file*, describing its first hit, then the
    #   file is abandoned. Cheap reconnaissance: "which files mention X".
    #   In this mode `max_matches` counts files and `max_matches_per_file`
    #   is ignored (it is effectively 1).
    enum Mode
      Lines
      Paths
    end

    # Why the walk finished.
    enum Stop
      Complete
      MaxMatches
      MaxFiles
      Timeout
    end

    record Match,
      path : String,
      relative_path : String,
      line_number : Int32,
      column : Int32,
      line : String,
      matched : String,
      truncated_line : Bool do
      def truncated_line?
        truncated_line
      end

      def to_s(io : IO) : Nil
        io << relative_path << ':' << line_number << ':' << column << ": " << line
      end
    end

    record Summary,
      matches : Int32,
      files_scanned : Int32,
      files_skipped : Int32,
      dirs_scanned : Int32,
      files_capped : Int32,
      dirs_capped : Int32,
      stopped : Stop,
      elapsed : Time::Span do
      # True when results are a partial sample rather than everything.
      def truncated?
        stopped != Stop::Complete || files_capped > 0 || dirs_capped > 0
      end
    end

    @base = ""
    @deadline = Time.instant
    @matches = 0
    @files_scanned = 0
    @files_skipped = 0
    @dirs_scanned = 0
    @files_capped = 0
    @dirs_capped = 0
    @stopped = Stop::Complete
    @visited = Set(String).new

    getter regex : Regex
    getter mode : Mode

    # `pattern` is a regular expression unless `fixed_string` is set.
    # `include`/`exclude` are globs matched against both the basename and the
    # path relative to the search root; `types` names entries in `TYPES` and is
    # merged into `include`.
    def initialize(
      @pattern : String,
      @path : String = ".",
      @mode : Mode = Mode::Lines,
      @fixed_string : Bool = false,
      @ignore_case : Bool = false,
      types : Array(String) = [] of String,
      @include : Array(String) = [] of String,
      @exclude : Array(String) = [] of String,
      @max_matches : Int32 = 1_000,
      @max_matches_per_file : Int32 = 20,
      @max_matches_per_dir : Int32 = 100,
      @max_depth : Int32 = 25,
      @max_files : Int32 = 20_000,
      @max_file_bytes : Int64 = 5_000_000_i64,
      @max_line_length : Int32 = 1_000,
      @follow_symlinks : Bool = false,
      @hidden : Bool = false,
      @skip_dirs : Array(String) = DEFAULT_SKIP_DIRS,
      @timeout : Time::Span = 10.seconds,
    )
      unless types.empty?
        @include = @include + types.flat_map do |name|
          TYPES[name.downcase]? || raise Error.new(
            "unknown type #{name.inspect}; known types: #{TYPES.keys.sort!.join(", ")}")
        end
      end

      source = @fixed_string ? Regex.escape(@pattern) : @pattern
      options = @ignore_case ? Regex::Options::IGNORE_CASE : Regex::Options::None
      @regex = begin
        Regex.new(source, options)
      rescue ex : ArgumentError
        raise Error.new("invalid pattern #{@pattern.inspect}: #{ex.message}")
      end
    end

    def run(&block : Match ->) : Summary
      started = Time.instant
      @deadline = started + @timeout
      @matches = @files_scanned = @files_skipped = 0
      @dirs_scanned = @files_capped = @dirs_capped = 0
      @stopped = Stop::Complete
      @visited = Set(String).new

      root = File.expand_path(@path)
      raise Error.new("path not found: #{@path}") unless File.exists?(root)

      if File.directory?(root)
        @base = root
        walk(root, block)
      else
        @base = File.dirname(root)
        scan_file(root, block, @max_matches_per_dir)
      end

      Summary.new(
        matches: @matches,
        files_scanned: @files_scanned,
        files_skipped: @files_skipped,
        dirs_scanned: @dirs_scanned,
        files_capped: @files_capped,
        dirs_capped: @dirs_capped,
        stopped: @stopped,
        elapsed: Time.instant - started,
      )
    end

    # Breadth-first, so an exhausted budget produces a wide sample rather than
    # everything from the first branch we happened to fall into.
    private def walk(root : String, block : Match ->) : Nil
      queue = Deque({String, Int32}).new
      mark_visited(root)
      queue << {root, 0}

      until queue.empty?
        dir, depth = queue.shift
        break if stop?

        scan_dir(dir, depth, block).each do |subdir|
          queue << {subdir, depth + 1} if mark_visited(subdir)
        end
      end
    end

    # Scans one directory's files against that directory's own budget, and
    # returns the subdirectories worth queueing.
    private def scan_dir(dir : String, depth : Int32, block : Match ->) : Array(String)
      subdirs = [] of String

      entries = begin
        Dir.children(dir).sort
      rescue
        @files_skipped += 1
        return subdirs
      end
      @dirs_scanned += 1

      budget = @max_matches_per_dir

      entries.each do |name|
        full = File.join(dir, name)

        case kind(name, full)
        when :dir
          subdirs << full if depth < @max_depth
        when :file
          break if stop?
          budget -= scan_file(full, block, budget)
          if budget <= 0
            @dirs_capped += 1
            break
          end
        end
      end

      subdirs
    end

    # `:dir`, `:file`, or nil for anything we decline to descend into or read.
    private def kind(name : String, full : String) : Symbol?
      return if !@hidden && name.starts_with?('.')
      return if !@follow_symlinks && symlink?(full)

      if directory?(full)
        @skip_dirs.includes?(name) ? nil : :dir
      elsif file?(full)
        :file
      end
    end

    # Returns the number of matches emitted from this file.
    private def scan_file(path : String, block : Match ->, dir_budget : Int32) : Int32
      name = File.basename(path)
      rel = relative(path)
      return 0 unless want?(name, rel)
      return 0 unless readable_size?(path)

      per_file = @mode.paths? ? 1 : @max_matches_per_file
      limit = {per_file, dir_budget, @max_matches - @matches}.min
      return 0 if limit <= 0

      begin
        File.open(path, "r") do |file|
          if binary?(file)
            @files_skipped += 1
            return 0
          end
          @files_scanned += 1
          return scan_lines(file, path, rel, limit, block)
        end
      rescue
        # Unreadable, vanished mid-scan, or otherwise hostile. Not fatal.
        @files_skipped += 1
      end

      0
    end

    private def readable_size?(path : String) : Bool
      size = begin
        File.info(path).size
      rescue
        @files_skipped += 1
        return false
      end

      return true if size <= @max_file_bytes
      @files_skipped += 1
      false
    end

    # Emits up to `limit` matches from an open file; returns how many.
    private def scan_lines(file : File, path : String, rel : String,
                           limit : Int32, block : Match ->) : Int32
      found = 0
      line_number = 0

      file.each_line(chomp: true) do |line|
        line_number += 1
        break if line_number % 256 == 0 && stop?

        md = match(line)
        next unless md

        block.call build_match(path, rel, line_number, line, md)
        found += 1
        @matches += 1

        if @matches >= @max_matches
          @stopped = Stop::MaxMatches
          break
        end
        if found >= limit
          @files_capped += 1 if !@mode.paths? && found >= @max_matches_per_file
          break
        end
      end

      found
    end

    private def build_match(path : String, rel : String, line_number : Int32,
                            line : String, md : Regex::MatchData) : Match
      text, truncated = clamp(line)
      Match.new(
        path: path,
        relative_path: rel,
        line_number: line_number,
        column: (md.begin(0) || 0) + 1,
        line: text,
        matched: md[0],
        truncated_line: truncated,
      )
    end

    private def match(line : String) : Regex::MatchData?
      @regex.match(line)
    rescue
      # Invalid UTF-8 and friends.
      nil
    end

    private def clamp(line : String) : {String, Bool}
      return {line, false} if line.size <= @max_line_length
      {line[0, @max_line_length], true}
    end

    private def want?(name : String, rel : String) : Bool
      unless @include.empty?
        return false unless @include.any? { |glob| File.match?(glob, name) || File.match?(glob, rel) }
      end
      return false if @exclude.any? { |glob| File.match?(glob, name) || File.match?(glob, rel) }
      true
    end

    private def binary?(file : File) : Bool
      buffer = Bytes.new(8192)
      read = file.read(buffer)
      file.rewind
      return false if read == 0
      buffer[0, read].includes?(0_u8)
    end

    private def stop? : Bool
      return true unless @stopped.complete?
      if Time.instant > @deadline
        @stopped = Stop::Timeout
        return true
      end
      if @files_scanned >= @max_files
        @stopped = Stop::MaxFiles
        return true
      end
      false
    end

    # Canonicalises when following symlinks so a cycle is entered once only.
    private def mark_visited(dir : String) : Bool
      key = if @follow_symlinks
              begin
                File.realpath(dir)
              rescue
                dir
              end
            else
              dir
            end
      return false if @visited.includes?(key)
      @visited << key
      true
    end

    private def relative(path : String) : String
      return path unless path.starts_with?(@base)
      rest = path[@base.size..]
      rest = rest[1..] if rest.starts_with?('/')
      rest.empty? ? File.basename(path) : rest
    end

    private def symlink?(path : String) : Bool
      File.symlink?(path)
    rescue
      false
    end

    private def directory?(path : String) : Bool
      File.directory?(path)
    rescue
      false
    end

    private def file?(path : String) : Bool
      File.file?(path)
    rescue
      false
    end
  end
end
