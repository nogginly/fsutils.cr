require "option_parser"
require "colorize"
require "../src/fsutils"

# fsu-grep — a small `grep`/`rg` work-alike, to demonstrate `FsUtils::Grep`.
#
# Familiar short flags keep their usual meaning; anything this shard invented
# gets a long name only.

# A bad number should be a message, not a stack trace.
def to_int(flag : String, value : String) : Int32
  value.to_i? || abort("fsu-grep: #{flag} expects a whole number, got #{value.inspect}")
end

def to_float(flag : String, value : String) : Float64
  value.to_f? || abort("fsu-grep: #{flag} expects a number, got #{value.inspect}")
end

pattern : String? = nil
roots = [] of String
mode = FsUtils::Grep::Mode::Lines
ignore_case = false
fixed_string = false
types = [] of String
includes = [] of String
excludes = [] of String
max_matches = 1_000
per_file = 20
per_dir = 100
max_depth = 25
timeout = 10.0
include_hidden = false
follow = false
quiet = false

parser = OptionParser.new do |opts|
  opts.banner = "Usage: fsu-grep PATTERN [ROOT...] [options]"

  opts.on("-i", "--ignore-case", "Case-insensitive matching") { ignore_case = true }
  opts.on("-F", "--fixed-strings", "Treat the pattern literally, not as a regex") { fixed_string = true }
  opts.on("-l", "--files-with-matches", "Print each matching file once, not every line") do
    mode = FsUtils::Grep::Mode::Paths
  end
  opts.on("-t TYPE", "--type TYPE", "File type by extension, e.g. cr, py (repeatable)") { |v| types << v }

  opts.separator "\nNot from grep(1):"
  opts.on("--include GLOB", "Only search files matching GLOB (repeatable)") { |v| includes << v }
  opts.on("--exclude GLOB", "Skip files matching GLOB (repeatable)") { |v| excludes << v }
  opts.on("--hidden", "Search dotfiles and dot-directories") { include_hidden = true }
  opts.on("--follow", "Follow symlinked directories") { follow = true }
  opts.on("--max-depth N", "Do not descend below N (default 25)") { |v| max_depth = to_int("--max-depth", v) }
  opts.on("--max-matches N", "Stop after N matches (default 1000)") { |v| max_matches = to_int("--max-matches", v) }
  opts.on("--per-file N", "Matches any one file may contribute (default 20)") { |v| per_file = to_int("--per-file", v) }
  opts.on("--per-dir N", "Matches any one directory may contribute (default 100)") { |v| per_dir = to_int("--per-dir", v) }
  opts.on("--timeout SECONDS", "Give up after SECONDS (default 10)") { |v| timeout = to_float("--timeout", v) }
  opts.on("--types", "List the known type names and exit") do
    puts FsUtils::Grep::TYPES.keys.sort!.join(", ")
    exit 0
  end
  opts.on("-q", "--quiet", "Suppress the trailing report") { quiet = true }

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end

  opts.unknown_args do |args|
    pattern = args.shift?
    roots = args
  end
  opts.invalid_option { |flag| abort "fsu-grep: #{flag}\n#{opts}" }
end

parser.parse

needle = pattern
abort "fsu-grep: no pattern given\n#{parser}" unless needle
roots = ["."] if roots.empty?
Colorize.enabled = STDOUT.tty?

grep = begin
  FsUtils::Grep.new(
    needle,
    roots,
    mode: mode,
    fixed_string: fixed_string,
    ignore_case: ignore_case,
    types: types,
    include: includes,
    exclude: excludes,
    max_matches: max_matches,
    max_matches_per_file: per_file,
    max_matches_per_dir: per_dir,
    max_depth: max_depth,
    follow_symlinks: follow,
    include_hidden: include_hidden,
    timeout: timeout.seconds,
  )
rescue ex : FsUtils::Error | ArgumentError
  abort "fsu-grep: #{ex.message}"
end

# Repaints the matched span within the line, using the column the Match
# reports. A truncated line may cut the match short, hence the bounds check.
def highlight(line : String, column : Int32, matched : String) : String
  start = column - 1
  finish = start + matched.size
  return line unless start >= 0 && finish <= line.size && line[start, matched.size] == matched
  String.build do |io|
    io << line[0, start]
    io << matched.colorize(:red).bold
    io << line[finish..]
  end
end

report = grep.run do |match|
  if mode.paths?
    puts match.relative_path.colorize(:cyan)
  else
    print match.relative_path.colorize(:cyan)
    print ":".colorize(:dark_gray)
    print match.line_number.colorize(:yellow)
    print ":".colorize(:dark_gray)
    print match.column.colorize(:yellow)
    print ": ".colorize(:dark_gray)
    print highlight(match.line, match.column, match.matched)
    puts match.truncated_line? ? " …".colorize(:dark_gray) : ""
  end
end

exit 0 if quiet

STDERR.puts
STDERR.puts "#{report.matches} matches in #{report.files_scanned} files, #{report.files_skipped} skipped, #{report.elapsed.total_milliseconds.round(1)}ms"
  .colorize(:dark_gray)

case report.stop_reason
when .max_matches?
  noun = mode.paths? ? "files" : "matches"
  STDERR.puts "stopped: max_matches — showed #{report.matches} #{noun}, there may be more. \
Narrow with --include or a more specific pattern.".colorize(:yellow)
when .max_entries_scanned?
  STDERR.puts "stopped: scanned #{report.scanned} entries without finishing. \
Narrow the root, or use --include.".colorize(:yellow)
when .timeout?
  STDERR.puts "stopped: timed out after #{timeout}s. \
Narrow the root, or raise --timeout.".colorize(:yellow)
end

if report.files_capped > 0
  STDERR.puts "#{report.files_capped} files hit their --per-file quota; \
try -l to see which files match instead.".colorize(:yellow)
end

if report.dirs_capped > 0
  STDERR.puts "#{report.dirs_capped} directories hit their --per-dir quota; \
results are a sample.".colorize(:yellow)
end

report.errors.first(10).each { |e| STDERR.puts "warning: #{e}".colorize(:red) }
if report.errors.size > 10
  STDERR.puts "warning: #{report.errors.size - 10} further errors omitted".colorize(:red)
end
