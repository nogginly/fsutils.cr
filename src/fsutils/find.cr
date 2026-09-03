module FsUtils
  # A bounded, breadth-first `find(1)` variant.
  #
  # ```
  # report = FsUtils::Find.new("src", name: ["*.cr"]).run do |m|
  #   puts m.path
  # end
  # puts report.stop_reason
  # ```
  class Find
    VERSION = "0.1.0"

    DEFAULT_SKIP_DIRS = %w[
      .git .hg .svn node_modules .venv venv __pycache__
      target vendor .cache .terraform .next dist
    ]

    enum EntryType
      File
      Directory
      Symlink
      Other
    end

    enum StopReason
      Completed
      MaxMatches
      MaxEntriesScanned
      Timeout

      def truncated? : Bool
        !completed?
      end
    end

    record Match,
      path : String,
      name : String,
      type : EntryType,
      size : Int64,
      modification_time : Time,
      depth : Int32,
      symlink : Bool do
      def file? : Bool
        type.file?
      end

      def directory? : Bool
        type.directory?
      end

      def symlink? : Bool
        symlink
      end

      def to_s(io : IO) : Nil
        io << path
      end
    end

    record Report,
      matches : Int32,
      scanned : Int32,
      directories : Int32,
      pruned : Int32,
      errors : Array(String),
      elapsed : Time::Span,
      stop_reason : StopReason do
      def truncated? : Bool
        stop_reason.truncated?
      end
    end

    # Convenience: a single root as a String.
    def self.new(root : String, **args)
      new([root], **args)
    end

    def initialize(
      @roots : Array(String),
      @name : Array(String) = [] of String,
      @path : Array(String) = [] of String,
      @exclude : Array(String) = [] of String,
      @type : EntryType? = nil,
      @min_depth : Int32 = 0,
      @max_depth : Int32 = 32,
      @max_matches : Int32 = 1_000,
      @max_matches_per_dir : Int32 = 100,
      @max_entries_scanned : Int32 = 100_000,
      @max_seconds : Float64 = 10.0,
      @follow_symlinks : Bool = false,
      @include_hidden : Bool = true,
      @min_size : Int64? = nil,
      @max_size : Int64? = nil,
      @newer_than : Time? = nil,
      @older_than : Time? = nil,
      @case_insensitive : Bool = false,
      @skip_dirs : Array(String) = DEFAULT_SKIP_DIRS,
    )
      raise ArgumentError.new("at least one root is required") if @roots.empty?
      raise ArgumentError.new("max_matches must be positive") if @max_matches < 1
      raise ArgumentError.new("max_depth must not be negative") if @max_depth < 0
    end

    def run(&block : Match ->) : Report
      state = State.new
      queue = Deque({String, Int32}).new
      @roots.each { |root| queue << {root, 0} }

      while state.stop.completed? && (entry = queue.shift?)
        scan(state, entry[0], entry[1], queue, block)
      end

      state.to_report
    end

    # Mutable bookkeeping for a single `run`. Kept out of the instance so a
    # `Find` can be reused, and out of `run`'s local scope so the traversal can
    # be split into readable pieces.
    # :nodoc:
    class State
      property matches = 0
      property scanned = 0
      property directories = 0
      property pruned = 0
      property stop = StopReason::Completed
      getter errors = [] of String
      getter seen = Set(String).new
      getter started = Time.instant

      def elapsed : Time::Span
        Time.instant - started
      end

      def to_report : Report
        Report.new(
          matches: matches,
          scanned: scanned,
          directories: directories,
          pruned: pruned,
          errors: errors,
          elapsed: elapsed,
          stop_reason: stop,
        )
      end
    end

    # ------------------------------------------------------------------ #
    # Traversal
    # ------------------------------------------------------------------ #

    private def scan(state, dir : String, depth : Int32, queue, block) : Nil
      real = real_path(dir, state.errors)
      return unless real

      if state.seen.includes?(real)
        state.pruned += 1
        return
      end
      state.seen << real
      state.directories += 1

      children = read_children(dir, state.errors)
      return unless children

      dir_matches = 0
      children.each do |name|
        state.scanned += 1
        if reason = over_budget(state)
          state.stop = reason
          return
        end

        next if !@include_hidden && name.starts_with?('.')

        dir_matches += visit(state, dir, name, depth + 1, dir_matches, queue, block)
        return unless state.stop.completed?
      end
    end

    # Handles one directory entry. Returns 1 if it was reported as a match.
    private def visit(state, dir, name, depth, dir_matches, queue, block) : Int32
      full = ::File.join(dir, name)
      pair = stat(full, state.errors)
      return 0 unless pair
      link_info, info = pair

      symlink = link_info.symlink?
      type = entry_type(link_info, info)
      matched = 0

      if dir_matches < @max_matches_per_dir && matches?(full, name, type, info, depth)
        block.call Match.new(
          path: full,
          name: name,
          type: type,
          size: info.size,
          modification_time: info.modification_time,
          depth: depth,
          symlink: symlink,
        )
        state.matches += 1
        matched = 1
        state.stop = StopReason::MaxMatches if state.matches >= @max_matches
      end

      queue << {full, depth} if descend?(name, info.directory?, symlink, depth)
      matched
    end

    private def over_budget(state) : StopReason?
      return StopReason::MaxEntriesScanned if state.scanned > @max_entries_scanned
      return StopReason::Timeout if state.elapsed.total_seconds > @max_seconds
      nil
    end

    private def descend?(name, directory : Bool, symlink, depth) : Bool
      return false unless directory
      return false if symlink && !@follow_symlinks
      return false if depth >= @max_depth
      return false if @skip_dirs.includes?(name)
      true
    end

    # ------------------------------------------------------------------ #
    # Filters
    # ------------------------------------------------------------------ #

    private def matches?(full, name, type : EntryType, info : ::File::Info, depth) : Bool
      return false if depth < @min_depth
      return false unless type_matches?(type)
      return false unless glob_matches?(full, name)
      return false unless size_matches?(type, info.size)
      time_matches?(info.modification_time)
    end

    private def type_matches?(type : EntryType) : Bool
      wanted = @type
      wanted.nil? || type == wanted
    end

    private def glob_matches?(full, name) : Bool
      return false unless @name.empty? || @name.any? { |pattern| glob?(pattern, name) }
      return false unless @path.empty? || @path.any? { |pattern| glob?(pattern, full) }
      @exclude.none? { |pattern| glob?(pattern, name) || glob?(pattern, full) }
    end

    private def size_matches?(type : EntryType, size : Int64) : Bool
      return true unless type.file?
      min = @min_size
      return false if min && size < min
      max = @max_size
      return false if max && size > max
      true
    end

    private def time_matches?(mtime : Time) : Bool
      newer = @newer_than
      return false if newer && mtime <= newer
      older = @older_than
      return false if older && mtime >= older
      true
    end

    private def glob?(pattern : String, subject : String) : Bool
      if @case_insensitive
        ::File.match?(pattern.downcase, subject.downcase)
      else
        ::File.match?(pattern, subject)
      end
    end

    # ------------------------------------------------------------------ #
    # Filesystem access — errors are collected, never raised
    # ------------------------------------------------------------------ #

    private def entry_type(link_info : ::File::Info, info : ::File::Info) : EntryType
      if link_info.symlink?
        EntryType::Symlink
      elsif info.directory?
        EntryType::Directory
      elsif info.file?
        EntryType::File
      else
        EntryType::Other
      end
    end

    # Returns `{link_info, target_info}`. The link info decides whether the
    # entry *is* a symlink; the target info decides what it points at (and so
    # whether it is worth descending into). A dangling link yields the link
    # twice rather than an error.
    private def stat(path : String, errors) : Tuple(::File::Info, ::File::Info)?
      link = ::File.info(path, follow_symlinks: false)
      return {link, link} unless link.symlink?
      target = begin
        ::File.info(path, follow_symlinks: true)
      rescue
        link
      end
      {link, target}
    rescue ex : ::File::Error | IO::Error
      errors << "#{path}: #{ex.message}"
      nil
    end

    private def real_path(dir : String, errors) : String?
      ::File.realpath(dir)
    rescue ex : ::File::Error | IO::Error
      errors << "#{dir}: #{ex.message}"
      nil
    end

    private def read_children(dir : String, errors) : Array(String)?
      entries = [] of String
      Dir.each_child(dir) { |child| entries << child }
      entries.sort!
    rescue ex : ::File::Error | IO::Error
      errors << "#{dir}: #{ex.message}"
      nil
    end
  end
end
