require "json"

require "./tools/envelope"
require "./tools/sandbox"
require "./tools/read"
require "./tools/schemas"

module FsUtils
  # The agent-facing layer.
  #
  # The helpers stream, are typed, and raise on caller error — right for
  # trusted local code. This layer does the opposite, because its caller is a
  # language model: it confines every path to a sandbox, buffers results,
  # bounds the size of what it returns, and **never raises**.
  #
  # ```
  # tools = FsUtils::Tools.new("/srv/project")
  # tools.grep(pattern: "TODO", paths: ["src"]).to_json
  # ```
  #
  # A raised exception becomes a stack trace in someone's tool harness. A JSON
  # error is something a model can read and recover from.
  class Tools
    # Serialised results beyond this are dropped. `max_matches` cannot do this
    # job: 200 grep matches may be 2 KB or 200 KB, and only the bytes know.
    DEFAULT_MAX_OUTPUT_BYTES = 32_000

    # Enough for a model to see the shape of the trouble; not so many that a
    # permissions-denied mount becomes the entire response.
    MAX_ERRORS = 10

    struct Summary
      include JSON::Serializable
      getter matches : Int32
      getter scanned : Int32
      getter elapsed_ms : Float64
      getter files_scanned : Int32?
      getter files_skipped : Int32?

      def initialize(@matches, @scanned, @elapsed_ms, @files_scanned = nil, @files_skipped = nil)
      end
    end

    struct FindResult
      include JSON::Serializable
      getter path : String
      getter type : String
      getter size : Int64
      getter modified : String

      def initialize(@path, @type, @size, @modified)
      end
    end

    struct GrepResult
      include JSON::Serializable
      getter path : String
      getter line : Int32
      getter column : Int32
      getter text : String
      getter truncated : Bool?

      def initialize(@path, @line, @column, @text, @truncated = nil)
      end
    end

    # The envelope for the searching tools, `find` and `grep`.
    #
    # `errors` and `errors_omitted` live here rather than in `Envelope`
    # because they exist for a walk: a traversal accumulates filesystem
    # trouble and carries on. A read either succeeds or fails.
    struct SearchResponse(T)
      include JSON::Serializable
      include Envelope

      getter results : Array(T)?
      getter summary : Summary?
      # Why the walk ended. `Envelope#truncated` says *that* the answer is a
      # sample; this says which budget ran out.
      getter stop_reason : String?
      getter errors : Array(String)?
      getter errors_omitted : Int32?

      def initialize(
        @ok,
        @results = nil,
        @summary = nil,
        @truncated = nil,
        @stop_reason = nil,
        @notice = nil,
        @errors = nil,
        @errors_omitted = nil,
        @error = nil,
      )
      end

      def self.failure(code : String, message : String, suggestion : String? = nil) : SearchResponse(T)
        new(ok: false, error: ErrorInfo.new(code, message, suggestion))
      end
    end

    getter sandbox : Sandbox
    getter max_output_bytes : Int32

    def initialize(root : String, @max_output_bytes : Int32 = DEFAULT_MAX_OUTPUT_BYTES)
      @sandbox = Sandbox.new(root)
    end

    # ------------------------------------------------------------------ #
    # find
    # ------------------------------------------------------------------ #

    def find(
      paths : Array(String) = [] of String,
      name : Array(String) = [] of String,
      path : Array(String) = [] of String,
      exclude : Array(String) = [] of String,
      type : String? = nil,
      min_depth : Int32 = 0,
      max_depth : Int32 = 32,
      max_matches : Int32 = 200,
      include_hidden : Bool = false,
      timeout_seconds : Float64 = 10.0,
    ) : SearchResponse(FindResult)
      roots = @sandbox.resolve_all(paths)
      if missing = missing_root(roots)
        return SearchResponse(FindResult).failure(*not_found(missing))
      end

      entry_type = parse_type(type)

      results = [] of FindResult
      report = Find.new(
        roots,
        name: name,
        path: path,
        exclude: exclude,
        type: entry_type,
        min_depth: min_depth,
        max_depth: max_depth,
        max_matches: max_matches,
        include_hidden: include_hidden,
        timeout: timeout_seconds.seconds,
      ).run do |match|
        results << FindResult.new(
          path: @sandbox.relative(match.path),
          type: match.type.to_s.downcase,
          size: match.size,
          modified: match.modification_time.to_rfc3339,
        )
      end

      results, dropped = fit(results)
      SearchResponse(FindResult).new(
        ok: true,
        results: results,
        summary: Summary.new(
          matches: report.matches,
          scanned: report.scanned,
          elapsed_ms: report.elapsed.total_milliseconds.round(1),
        ),
        truncated: truncated?(report, dropped),
        stop_reason: report.stop_reason.to_s.underscore,
        notice: find_notice(report, dropped),
        errors: capped_errors(report.errors),
        errors_omitted: omitted_errors(report.errors),
      )
    rescue ex : Sandbox::Escape
      SearchResponse(FindResult).failure(
        ErrorCode::OUTSIDE_SANDBOX, ex.message || "path outside sandbox", outside_sandbox_suggestion)
    rescue ex : FsUtils::Error
      SearchResponse(FindResult).failure(
        ErrorCode::INVALID_ARGUMENT, ex.message || "invalid argument", ex.suggestion)
    rescue ex : ArgumentError
      SearchResponse(FindResult).failure(ErrorCode::INVALID_ARGUMENT, ex.message || "invalid argument")
    end

    # ------------------------------------------------------------------ #
    # grep
    # ------------------------------------------------------------------ #

    def grep(
      pattern : String,
      paths : Array(String) = [] of String,
      mode : String = "lines",
      ignore_case : Bool = false,
      fixed_string : Bool = false,
      types : Array(String) = [] of String,
      include_globs : Array(String) = [] of String,
      exclude_globs : Array(String) = [] of String,
      max_matches : Int32 = 200,
      max_matches_per_file : Int32 = 20,
      max_depth : Int32 = 25,
      include_hidden : Bool = false,
      timeout_seconds : Float64 = 10.0,
    ) : SearchResponse(GrepResult)
      roots = @sandbox.resolve_all(paths)
      if missing = missing_root(roots)
        return SearchResponse(GrepResult).failure(*not_found(missing))
      end

      grep_mode = parse_mode(mode)

      results = [] of GrepResult
      report = Grep.new(
        pattern,
        roots,
        mode: grep_mode,
        ignore_case: ignore_case,
        fixed_string: fixed_string,
        types: types,
        include: include_globs,
        exclude: exclude_globs,
        max_matches: max_matches,
        max_matches_per_file: max_matches_per_file,
        max_depth: max_depth,
        include_hidden: include_hidden,
        timeout: timeout_seconds.seconds,
      ).run do |match|
        results << GrepResult.new(
          path: @sandbox.relative(match.path),
          line: match.line_number,
          column: match.column,
          text: match.line,
          truncated: match.truncated_line? || nil,
        )
      end

      results, dropped = fit(results)
      SearchResponse(GrepResult).new(
        ok: true,
        results: results,
        summary: Summary.new(
          matches: report.matches,
          scanned: report.scanned,
          elapsed_ms: report.elapsed.total_milliseconds.round(1),
          files_scanned: report.files_scanned,
          files_skipped: report.files_skipped,
        ),
        truncated: truncated?(report, dropped) || report.files_capped > 0 || nil,
        stop_reason: report.stop_reason.to_s.underscore,
        notice: grep_notice(report, dropped, grep_mode),
        errors: capped_errors(report.errors),
        errors_omitted: omitted_errors(report.errors),
      )
    rescue ex : Sandbox::Escape
      SearchResponse(GrepResult).failure(
        ErrorCode::OUTSIDE_SANDBOX, ex.message || "path outside sandbox", outside_sandbox_suggestion)
    rescue ex : FsUtils::Error
      code, suggestion = classify(ex)
      SearchResponse(GrepResult).failure(code, ex.message || "invalid argument", suggestion)
    rescue ex : ArgumentError
      SearchResponse(GrepResult).failure(ErrorCode::INVALID_ARGUMENT, ex.message || "invalid argument")
    end

    # ------------------------------------------------------------------ #
    # Shared plumbing
    # ------------------------------------------------------------------ #

    private def missing_root(roots : Array(String)) : String?
      roots.find { |root| !::File.exists?(root) }
    end

    # The `not_found` triple, ready to splat into any response's `failure`.
    private def not_found(path : String) : {String, String, String}
      {ErrorCode::NOT_FOUND,
       "#{@sandbox.relative(path)} does not exist",
       not_found_suggestion(path)}
    end

    # A bad regex and a bad argument arrive as the same exception type, and
    # only the message tells them apart.
    private def classify(ex : FsUtils::Error) : {String, String?}
      if ex.message.to_s.includes?("pattern")
        {ErrorCode::INVALID_PATTERN,
         "Escape the regex metacharacters, or set `fixed_string: true` \
to match the text literally."}
      else
        {ErrorCode::INVALID_ARGUMENT, ex.suggestion}
      end
    end

    # Suggestions are written once and shared, so `find` and `grep` do not
    # drift into telling a model two different things about the same failure.
    private def outside_sandbox_suggestion : String
      "Paths must stay inside the workspace. Use a path relative to its root, \
without `..`, and do not follow symlinks out of it."
    end

    private def not_found_suggestion(path : String) : String
      "Check the spelling, or locate it with find_files using \
`name: [#{::File.basename(path).inspect}]`."
    end

    private def parse_type(type : String?) : Walk::EntryType?
      return unless type
      case type.downcase
      when "file", "f"      then Walk::EntryType::File
      when "directory", "d" then Walk::EntryType::Directory
      when "symlink", "l"   then Walk::EntryType::Symlink
      else
        raise FsUtils::Error.new(
          "unknown type #{type.inspect}",
          "Use one of: file, directory, symlink. Omit `type` to match any.")
      end
    end

    private def parse_mode(mode : String) : Grep::Mode
      case mode.downcase
      when "lines" then Grep::Mode::Lines
      when "paths" then Grep::Mode::Paths
      else
        raise FsUtils::Error.new(
          "unknown mode #{mode.inspect}",
          "Use \"lines\" for every matching line, or \"paths\" for one result per file.")
      end
    end

    # Drops results from the tail until the serialised array fits the budget.
    # Sized by summing each result rather than re-serialising the whole array,
    # which would be quadratic for the case that needs it most.
    private def fit(results : Array(T)) : {Array(T), Int32} forall T
      budget = @max_output_bytes
      kept = 0
      used = 0

      results.each do |result|
        used += result.to_json.bytesize + 1
        break if used > budget
        kept += 1
      end

      return {results, 0} if kept == results.size
      {results[0, kept], results.size - kept}
    end

    private def truncated?(report, dropped : Int32) : Bool?
      report.truncated? || dropped > 0 || nil
    end

    private def capped_errors(errors : Array(String)) : Array(String)?
      return if errors.empty?
      errors.first(MAX_ERRORS)
    end

    private def omitted_errors(errors : Array(String)) : Int32?
      extra = errors.size - MAX_ERRORS
      extra > 0 ? extra : nil
    end

    # A model acts on an instruction far more reliably than it reasons from an
    # enum, so every truncation says what to do about it.
    private def find_notice(report, dropped : Int32) : String?
      notes = [] of String

      case report.stop_reason
      when .max_matches?
        notes << "Stopped at #{report.matches} matches; there may be more. \
Narrow with `name` or `path`, or raise `max_matches`."
      when .max_entries_scanned?
        notes << "Scanned #{report.scanned} entries without finishing. \
Search a narrower path."
      when .timeout?
        notes << "Timed out. Search a narrower path, or raise `timeout_seconds`."
      end

      notes << "#{report.dirs_capped} directories hit their per-directory quota; \
results are a sample of those directories." if report.dirs_capped > 0

      notes << "#{dropped} results were dropped to fit the output budget; \
narrow the search rather than paging." if dropped > 0

      notes.empty? ? nil : notes.join(" ")
    end

    private def grep_notice(report, dropped : Int32, mode : Grep::Mode) : String?
      notes = [] of String

      case report.stop_reason
      when .max_matches?
        noun = mode.paths? ? "files" : "matches"
        notes << "Stopped at #{report.matches} #{noun}; there may be more. \
Narrow with `include_globs` or a more specific pattern, or raise `max_matches`."
      when .max_entries_scanned?
        notes << "Scanned #{report.scanned} entries without finishing. \
Search a narrower path, or use `include_globs`."
      when .timeout?
        notes << "Timed out. Search a narrower path, or raise `timeout_seconds`."
      end

      notes << "#{report.files_capped} files hit their per-file quota; \
use `mode: \"paths\"` to see which files match instead." if report.files_capped > 0

      notes << "#{report.dirs_capped} directories hit their per-directory quota; \
results are a sample of those directories." if report.dirs_capped > 0

      notes << "#{dropped} results were dropped to fit the output budget; \
narrow the search rather than paging." if dropped > 0

      notes.empty? ? nil : notes.join(" ")
    end
  end
end
