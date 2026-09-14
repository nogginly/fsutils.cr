module FsUtils
  # A `find(1)`-flavoured filter over `Walker`.
  #
  # ```
  # report = FsUtils::Find.new("src", name: ["*.cr"]).run do |m|
  #   puts m.path
  # end
  # report.truncated? # => did we stop early, and why
  # ```
  #
  # Nothing is buffered: the block sees each hit as it is found, so memory is
  # O(frontier), not O(results). An instance is single-use per `run` and not
  # thread-safe.
  class Find
    # `Find` speaks the walker's vocabulary rather than inventing its own.
    alias Match = Walk::Entry
    alias EntryType = Walk::EntryType
    alias StopReason = Walk::StopReason

    DEFAULT_SKIP_DIRS = Walk::DEFAULT_SKIP_DIRS

    # What the walk cost and why it ended. Composed from `Walk::Report` rather
    # than inheriting it: `Find` has nothing of its own to add, but `Grep` does,
    # and both should read the same way.
    record Report, walk : Walk::Report do
      delegate matches, scanned, directories, pruned, dirs_capped,
        errors, elapsed, stop_reason, truncated?, to: @walk
    end

    # The filter predicate, separated from the traversal so it can be reasoned
    # about — and tested — on its own.
    private struct Criteria
      def initialize(
        @name : Array(String) = [] of String,
        @path : Array(String) = [] of String,
        @exclude : Array(String) = [] of String,
        @type : EntryType? = nil,
        @min_depth : Int32 = 0,
        @min_size : Int64? = nil,
        @max_size : Int64? = nil,
        @newer_than : Time? = nil,
        @older_than : Time? = nil,
        @case_insensitive : Bool = false,
      )
      end

      def matches?(entry : Match) : Bool
        return false if entry.depth < @min_depth
        return false unless type_matches?(entry.type)
        return false unless glob_matches?(entry.path, entry.name)
        return false unless size_matches?(entry.type, entry.size)
        time_matches?(entry.modification_time)
      end

      private def type_matches?(type : EntryType) : Bool
        wanted = @type
        wanted.nil? || type == wanted
      end

      # `name` globs match the basename; `path` globs match the whole path, so
      # they nearly always want a leading `**/` — a single `*` does not cross a
      # `/`. `exclude` matches either.
      private def glob_matches?(full : String, name : String) : Bool
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

      # Crude, correct for ASCII, good enough for filenames.
      private def glob?(pattern : String, subject : String) : Bool
        if @case_insensitive
          ::File.match?(pattern.downcase, subject.downcase)
        else
          ::File.match?(pattern, subject)
        end
      end
    end

    # The walker policy: apply the criteria, hand survivors to the block.
    #
    # `Find` never needs more than one match per entry, so `limit` is only
    # checked for being positive — the walker guarantees it is. `Grep`, which
    # can emit many matches from one file, does the interesting thing with it.
    private struct Filter
      include Walk::Policy

      def initialize(@criteria : Criteria, @block : Match ->)
      end

      def visit(entry : Match, limit : Int32) : Int32
        return 0 unless @criteria.matches?(entry)
        @block.call(entry)
        1
      end
    end

    # The bounds this search honours. `Find` adds nothing to the traversal's
    # own, so the two are the same type.
    alias Settings = Walk::Settings

    # Convenience: a single root as a String.
    def self.new(root : String, **args)
      new([root], **args)
    end

    # Block form: the settings are yielded for amendment before the search is
    # built.
    #
    # ```
    # FsUtils::Find.new("src", name: ["*.cr"]) { |s| s.max_matches = 50 }
    # ```
    def self.new(roots : Array(String), **args, &)
      settings = Settings.new
      yield settings
      new(roots, **args, settings: settings)
    end

    def self.new(root : String, **args, &)
      new([root], **args) { |settings| yield settings }
    end

    def initialize(
      @roots : Array(String),
      name : Array(String) = [] of String,
      path : Array(String) = [] of String,
      exclude : Array(String) = [] of String,
      type : EntryType? = nil,
      min_depth : Int32 = 0,
      min_size : Int64? = nil,
      max_size : Int64? = nil,
      newer_than : Time? = nil,
      older_than : Time? = nil,
      case_insensitive : Bool = false,
      @settings : Settings = Settings.new,
    )
      # Validated here as well as in `Walker` so nonsense is caught at
      # construction rather than at `run`.
      raise ArgumentError.new("at least one root is required") if @roots.empty?
      @settings.validate!
      raise ArgumentError.new("min_depth must not be negative") if min_depth < 0

      @criteria = Criteria.new(
        name: name,
        path: path,
        exclude: exclude,
        type: type,
        min_depth: min_depth,
        min_size: min_size,
        max_size: max_size,
        newer_than: newer_than,
        older_than: older_than,
        case_insensitive: case_insensitive,
      )
    end

    def run(&block : Match ->) : Report
      walker = Walker.new(Filter.new(@criteria, block), @roots, @settings)
      Report.new(walker.run)
    end
  end
end
