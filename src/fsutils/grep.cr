module FsUtils
  # A `grep`-alike with guard rails, intended to back an agent's `search_files`
  # tool. Matches are yielded as they are found; `run` returns a `Report`.
  #
  # ```
  # report = FsUtils::Grep.new("TODO", "src").run do |m|
  #   puts "#{m.relative_path}:#{m.line_number}: #{m.line}"
  # end
  # ```
  #
  # An instance is single-use per `run` and not thread-safe; create a new one
  # per search.
  class Grep
    # Raised for a bad pattern or an unknown type name. Filesystem trouble is
    # collected into `Report#errors` instead.
    alias Error = FsUtils::Error
    alias StopReason = Walk::StopReason

    DEFAULT_SKIP_DIRS = Walk::DEFAULT_SKIP_DIRS

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
    #   In this mode `max_matches` counts files and `max_matches_per_file` is
    #   ignored (it is effectively 1).
    enum Mode
      Lines
      Paths
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

    # The walk's own accounting, plus the three counters only content search
    # has an opinion about.
    record Report,
      walk : Walk::Report,
      files_scanned : Int32,
      files_skipped : Int32,
      files_capped : Int32 do
      delegate matches, scanned, directories, pruned, dirs_capped,
        errors, elapsed, stop_reason, to: @walk

      # True when the results are a sample rather than everything: either the
      # walk stopped early, or some file or directory forfeited its remainder.
      def truncated? : Bool
        @walk.truncated? || files_capped > 0
      end
    end

    # Which files are worth opening. Separated from the scanning so the glob
    # rules can be reasoned about — and tested — on their own.
    private struct Selector
      def initialize(
        @include : Array(String) = [] of String,
        @exclude : Array(String) = [] of String,
        @max_file_bytes : Int64 = 5_000_000_i64,
      )
      end

      # Globs are matched against both the basename and the path relative to
      # the root, so `*.cr` and `src/**/*.cr` both do what a caller expects.
      def want?(name : String, rel : String) : Bool
        unless @include.empty?
          return false unless @include.any? { |glob| hit?(glob, name, rel) }
        end
        @exclude.none? { |glob| hit?(glob, name, rel) }
      end

      private def hit?(glob : String, name : String, rel : String) : Bool
        ::File.match?(glob, name) || ::File.match?(glob, rel)
      end

      def size_ok?(size : Int64) : Bool
        size <= @max_file_bytes
      end
    end

    # The walker policy. A class rather than a struct because it accumulates
    # counters across the whole walk; `Walker(P)` is indifferent either way.
    #
    # This is where `limit` earns its keep. `Find` emits at most one match per
    # entry and can ignore it; one file here may hold twenty.
    private class Scanner
      include Walk::Policy

      getter files_scanned = 0
      getter files_skipped = 0
      getter files_capped = 0

      def initialize(
        @regex : Regex,
        @selector : Selector,
        @bases : Array(String),
        @mode : Mode,
        @max_matches_per_file : Int32,
        @max_line_length : Int32,
        timeout : Time::Span,
        @block : Match ->,
      )
        @deadline = Time.instant + timeout
      end

      def visit(entry : Walk::Entry, limit : Int32) : Int32
        return 0 unless entry.file?

        rel = relative(entry.path)
        return 0 unless @selector.want?(entry.name, rel)

        unless @selector.size_ok?(entry.size)
          @files_skipped += 1
          return 0
        end

        # In `Paths` mode one hit settles the question, so stop at the first.
        per_file = @mode.paths? ? 1 : @max_matches_per_file
        allowed = {per_file, limit}.min
        return 0 if allowed < 1

        found = read(entry.path, rel, allowed)

        # `files_capped` means *this file* forfeited a remainder. When `limit`
        # was the tighter constraint the walker's own counters explain the
        # shortfall, and claiming it here would double-count.
        @files_capped += 1 if !@mode.paths? && found == per_file && per_file <= limit
        found
      end

      private def read(path : String, rel : String, allowed : Int32) : Int32
        ::File.open(path, "r") do |file|
          if binary?(file)
            @files_skipped += 1
            return 0
          end
          @files_scanned += 1
          return scan_lines(file, path, rel, allowed)
        end
      rescue
        # Unreadable, vanished mid-walk, or otherwise hostile. Not fatal.
        @files_skipped += 1
        0
      end

      # Emits up to `allowed` matches from an open file; returns how many.
      private def scan_lines(file : ::File, path : String, rel : String,
                             allowed : Int32) : Int32
        found = 0
        line_number = 0

        file.each_line(chomp: true) do |line|
          line_number += 1
          # The walker checks the clock between entries; a single enormous file
          # needs checking within one.
          break if line_number % 256 == 0 && Time.instant > @deadline

          md = match(line)
          next unless md

          @block.call build_match(path, rel, line_number, line, md)
          found += 1
          break if found >= allowed
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

      # Matches are noise in a binary and garbage on the way out.
      private def binary?(file : ::File) : Bool
        buffer = Bytes.new(8192)
        read = file.read(buffer)
        file.rewind
        return false if read == 0
        buffer[0, read].includes?(0_u8)
      end

      # Relative to whichever root the path falls under. The separator check is
      # not decoration: a bare prefix test lets `/srv/project-secrets` pass for
      # base `/srv/project`.
      private def relative(path : String) : String
        @bases.each do |base|
          next unless path.starts_with?(base)
          rest = path[base.size..]
          return ::File.basename(path) if rest.empty?
          return rest[1..] if rest.starts_with?(::File::SEPARATOR)
        end
        path
      end
    end

    getter regex : Regex
    getter mode : Mode

    # Declared: the compiler cannot infer these through `map`'s block.
    @roots : Array(String)
    @bases : Array(String)

    # Convenience: a single root as a String.
    def self.new(pattern : String, root : String, **args)
      new(pattern, [root], **args)
    end

    # `pattern` is a regular expression unless `fixed_string` is set.
    # `types` names entries in `TYPES` and is merged into `include`.
    def initialize(
      @pattern : String,
      roots : Array(String) = ["."],
      @mode : Mode = Mode::Lines,
      fixed_string : Bool = false,
      ignore_case : Bool = false,
      types : Array(String) = [] of String,
      @include : Array(String) = [] of String,
      @exclude : Array(String) = [] of String,
      @max_matches : Int32 = 1_000,
      @max_matches_per_file : Int32 = 20,
      @max_matches_per_dir : Int32 = 100,
      @max_depth : Int32 = 25,
      @max_entries_scanned : Int32 = 20_000,
      max_file_bytes : Int64 = 5_000_000_i64,
      @max_line_length : Int32 = 1_000,
      @follow_symlinks : Bool = false,
      @include_hidden : Bool = false,
      @skip_dirs : Array(String) = DEFAULT_SKIP_DIRS,
      @timeout : Time::Span = 10.seconds,
    )
      raise ArgumentError.new("at least one root is required") if roots.empty?
      raise ArgumentError.new("max_matches must be positive") if @max_matches < 1
      raise ArgumentError.new("max_matches_per_file must be positive") if @max_matches_per_file < 1

      unless types.empty?
        @include = @include + types.flat_map do |name|
          TYPES[name.downcase]? || raise Error.new(
            "unknown type #{name.inspect}; known types: #{TYPES.keys.sort!.join(", ")}")
        end
      end
      # Positional: `include:` is not a usable argument label either.
      @selector = Selector.new(@include, @exclude, max_file_bytes)

      # Roots are expanded so relative paths can be derived by prefix. Longest
      # first, so a nested root wins over the parent that contains it.
      @roots = roots.map { |root| ::File.expand_path(root) }
      @bases = @roots.map { |root| ::File.directory?(root) ? root : ::File.dirname(root) }
      @bases.sort_by! { |base| -base.size }

      source = fixed_string ? Regex.escape(@pattern) : @pattern
      options = ignore_case ? Regex::Options::IGNORE_CASE : Regex::Options::None
      @regex = begin
        Regex.new(source, options)
      rescue ex : ArgumentError
        raise Error.new("invalid pattern #{@pattern.inspect}: #{ex.message}")
      end
    end

    def run(&block : Match ->) : Report
      scanner = Scanner.new(
        regex: @regex,
        selector: @selector,
        bases: @bases,
        mode: @mode,
        max_matches_per_file: @max_matches_per_file,
        max_line_length: @max_line_length,
        timeout: @timeout,
        block: block,
      )

      walker = Walker.new(
        scanner,
        @roots,
        max_matches: @max_matches,
        max_matches_per_dir: @max_matches_per_dir,
        max_entries_scanned: @max_entries_scanned,
        max_depth: @max_depth,
        timeout: @timeout,
        follow_symlinks: @follow_symlinks,
        include_hidden: @include_hidden,
        skip_dirs: @skip_dirs,
      )

      Report.new(
        walk: walker.run,
        files_scanned: scanner.files_scanned,
        files_skipped: scanner.files_skipped,
        files_capped: scanner.files_capped,
      )
    end
  end
end
