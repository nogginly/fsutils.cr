module FsUtils
  # Raised for caller error that a helper cannot recover from: a bad pattern,
  # a missing root. Filesystem trouble encountered *during* a walk is collected
  # into `Report#errors` instead.
  class Error < Exception; end

  # Types shared by `Walker` and its policies.
  #
  # These live outside `Walker(P)` on purpose. Nesting them inside a generic
  # class would make every reference to them depend on `P`, which is both a
  # nuisance to write and pointless — an `Entry` is an `Entry` whoever is
  # looking at it.
  module Walk
    DEFAULT_SKIP_DIRS = %w[
      .git .hg .svn node_modules lib vendor .venv venv
      target build dist __pycache__ .cache .terraform .next
    ]

    enum EntryType
      File
      Directory
      Symlink
      Other
    end

    # Why the walk finished.
    enum StopReason
      Completed
      MaxMatches
      MaxEntriesScanned
      Timeout

      def truncated? : Bool
        !completed?
      end
    end

    # One directory entry, offered to a policy. A record rather than a tuple so
    # fields can be added later without breaking callers.
    record Entry,
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

    # What the traversal itself spent and why it stopped. Helpers compose this
    # into their own report rather than inheriting from it, so `Grep` can add
    # counters that mean nothing to `Find`.
    record Report,
      matches : Int32,
      scanned : Int32,
      directories : Int32,
      pruned : Int32,
      dirs_capped : Int32,
      errors : Array(String),
      elapsed : Time::Span,
      stop_reason : StopReason do
      # True when the result is a sample rather than everything.
      def truncated? : Bool
        stop_reason.truncated? || dirs_capped > 0
      end
    end

    # The interface `Walker(P)` expects of `P`.
    #
    # A module rather than an abstract base class, deliberately. `Walker(P)`
    # stores the policy as `P`, so calls monomorphise to direct calls and
    # inline; typing it as a shared abstract parent would reintroduce virtual
    # dispatch for no benefit. Including this module documents the contract and
    # gets the compiler to check it, without ever being used as a type.
    #
    # Policies may be structs — they live for exactly one `run`.
    module Policy
      # Called for every entry that survives traversal filtering (hidden,
      # unreadable). Returns how many matches were emitted, which must be
      # between `0` and `limit`.
      #
      # `limit` is the walker's budget arithmetic made explicit:
      # `min(remaining directory quota, max_matches - matches so far)`. It is
      # always positive. A policy may narrow it further — `Grep` applies its
      # own per-file cap — but must never exceed it.
      abstract def visit(entry : Entry, limit : Int32) : Int32

      # Called before a directory's children are read. Return `false` to prune
      # it; the walker counts the prune and does not descend.
      def enter_dir(dir : String, depth : Int32) : Bool
        true
      end

      # Called after a directory is finished, including when it was unreadable.
      # Not called for a directory pruned by `enter_dir`.
      def leave_dir(dir : String, depth : Int32) : Nil
      end
    end
  end

  # A bounded, breadth-first directory walk.
  #
  # `Walker` knows about directories, budgets, cycles and clocks. It has no
  # opinion about what makes a match — that is the policy's job.
  #
  # ```
  # policy = MyPolicy.new
  # report = FsUtils::Walker.new(policy, "src").run
  # report.stop_reason # => Completed
  # ```
  #
  # Breadth-first on purpose: depth-first plus a match limit means the first
  # deep directory encountered spends the entire budget. An instance is
  # single-use per `run` and not thread-safe.
  class Walker(P)
    # Convenience for a single root.
    def self.new(policy : P, root : String, **args)
      new(policy, [root], **args)
    end

    def initialize(
      @policy : P,
      @roots : Array(String),
      @max_matches : Int32 = 1_000,
      @max_matches_per_dir : Int32 = 100,
      @max_entries_scanned : Int32 = 100_000,
      @max_depth : Int32 = 32,
      @timeout : Time::Span = 10.seconds,
      @follow_symlinks : Bool = false,
      @include_hidden : Bool = false,
      @skip_dirs : Array(String) = Walk::DEFAULT_SKIP_DIRS,
    )
      raise ArgumentError.new("at least one root is required") if @roots.empty?
      raise ArgumentError.new("max_matches must be positive") if @max_matches < 1
      raise ArgumentError.new("max_matches_per_dir must be positive") if @max_matches_per_dir < 1
      raise ArgumentError.new("max_depth must not be negative") if @max_depth < 0
    end

    def run : Walk::Report
      state = State.new(@timeout)
      queue = Deque({String, Int32}).new

      # A root that is a plain file is offered directly. Callers point these
      # helpers at a single file often enough that failing with "not a
      # directory" would be a poor joke.
      @roots.each do |root|
        if directory?(root)
          queue << {root, 0}
        else
          visit_root_file(state, root)
        end
      end

      while state.stop.completed? && (item = queue.shift?)
        scan(state, item[0], item[1], queue)
      end

      state.to_report
    end

    # Mutable bookkeeping for one `run`. Kept out of the instance so a `Walker`
    # can be run twice, and out of `run`'s scope so the traversal can be split
    # into readable pieces.
    # :nodoc:
    class State
      property matches = 0
      property scanned = 0
      property directories = 0
      property pruned = 0
      property dirs_capped = 0
      property stop = Walk::StopReason::Completed
      getter errors = [] of String
      getter seen = Set(String).new
      getter started = Time.instant
      getter deadline

      def initialize(timeout : Time::Span)
        @deadline = @started + timeout
      end

      def elapsed : Time::Span
        Time.instant - started
      end

      def to_report : Walk::Report
        Walk::Report.new(
          matches: matches,
          scanned: scanned,
          directories: directories,
          pruned: pruned,
          dirs_capped: dirs_capped,
          errors: errors,
          elapsed: elapsed,
          stop_reason: stop,
        )
      end
    end

    # ------------------------------------------------------------------ #
    # Traversal
    # ------------------------------------------------------------------ #

    private def scan(state : State, dir : String, depth : Int32, queue) : Nil
      real = real_path(dir, state)
      return unless real

      if state.seen.includes?(real)
        state.pruned += 1
        return
      end
      state.seen << real

      unless @policy.enter_dir(dir, depth)
        state.pruned += 1
        return
      end

      state.directories += 1
      children = read_children(dir, state)

      scan_children(state, dir, depth, children, queue) if children

      @policy.leave_dir(dir, depth)
    end

    private def scan_children(state : State, dir : String, depth : Int32,
                              children : Array(String), queue) : Nil
      budget = @max_matches_per_dir
      capped = false

      children.each do |name|
        state.scanned += 1
        if reason = over_budget(state)
          state.stop = reason
          return
        end

        next if !@include_hidden && name.starts_with?('.')

        full = ::File.join(dir, name)
        pair = stat(full, state)
        next unless pair
        link_info, info = pair

        symlink = link_info.symlink?
        type = entry_type(link_info, info)
        child_depth = depth + 1

        unless capped
          spent = offer(state, full, name, type, info, child_depth, budget)
          budget -= spent
          if state.matches >= @max_matches
            state.stop = Walk::StopReason::MaxMatches
          elsif budget <= 0
            # The directory is done contributing matches, but its children are
            # still queued: one fat directory forfeits its own quota, not its
            # subtree's.
            state.dirs_capped += 1
            capped = true
          end
        end

        queue << {full, child_depth} if descend?(name, info.directory?, symlink, child_depth)
        return unless state.stop.completed?
      end
    end

    # Offers one entry to the policy under an explicit limit. Returns how many
    # matches the policy actually emitted.
    private def offer(state : State, full : String, name : String,
                      type : Walk::EntryType, info : ::File::Info,
                      depth : Int32, budget : Int32) : Int32
      limit = {budget, @max_matches - state.matches}.min
      return 0 if limit < 1

      entry = Walk::Entry.new(
        path: full,
        name: name,
        type: type,
        size: info.size,
        modification_time: info.modification_time,
        depth: depth,
        symlink: type.symlink?,
      )

      # A misbehaving policy clamps rather than corrupts the counters.
      found = @policy.visit(entry, limit).clamp(0, limit)
      state.matches += found
      found
    end

    private def visit_root_file(state : State, path : String) : Nil
      return unless state.stop.completed?

      pair = stat(path, state)
      return unless pair
      link_info, info = pair

      state.scanned += 1
      type = entry_type(link_info, info)
      offer(state, path, ::File.basename(path), type, info, 0, @max_matches_per_dir)
      state.stop = Walk::StopReason::MaxMatches if state.matches >= @max_matches
    end

    private def over_budget(state : State) : Walk::StopReason?
      return Walk::StopReason::MaxEntriesScanned if state.scanned > @max_entries_scanned
      return Walk::StopReason::Timeout if Time.instant > state.deadline
      nil
    end

    private def descend?(name : String, directory : Bool, symlink : Bool, depth : Int32) : Bool
      return false unless directory
      return false if symlink && !@follow_symlinks
      return false if depth >= @max_depth
      return false if @skip_dirs.includes?(name)
      true
    end

    # ------------------------------------------------------------------ #
    # Filesystem access — errors are collected, never raised
    # ------------------------------------------------------------------ #

    private def entry_type(link_info : ::File::Info, info : ::File::Info) : Walk::EntryType
      if link_info.symlink?
        Walk::EntryType::Symlink
      elsif info.directory?
        Walk::EntryType::Directory
      elsif info.file?
        Walk::EntryType::File
      else
        Walk::EntryType::Other
      end
    end

    # Returns `{link_info, target_info}`. The link info decides whether the
    # entry *is* a symlink; the target info decides what it points at, and so
    # whether it is worth descending into. A dangling link yields the link
    # twice rather than an error.
    private def stat(path : String, state : State) : Tuple(::File::Info, ::File::Info)?
      link = ::File.info(path, follow_symlinks: false)
      return {link, link} unless link.symlink?
      target = begin
        ::File.info(path, follow_symlinks: true)
      rescue
        link
      end
      {link, target}
    rescue ex : ::File::Error | IO::Error
      state.errors << "#{path}: #{ex.message}"
      nil
    end

    # Canonicalised so a symlink cycle is entered exactly once, and so
    # overlapping roots (`["src", "src/."]`) deduplicate for free.
    private def real_path(dir : String, state : State) : String?
      ::File.realpath(dir)
    rescue ex : ::File::Error | IO::Error
      state.errors << "#{dir}: #{ex.message}"
      nil
    end

    # Sorted, so two runs over an unchanged tree produce identical output.
    private def read_children(dir : String, state : State) : Array(String)?
      entries = [] of String
      Dir.each_child(dir) { |child| entries << child }
      entries.sort!
    rescue ex : ::File::Error | IO::Error
      state.errors << "#{dir}: #{ex.message}"
      nil
    end

    private def directory?(path : String) : Bool
      ::File.directory?(path)
    rescue
      false
    end
  end
end
