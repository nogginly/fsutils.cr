require "option_parser"
require "colorize"
require "../src/fsutils"

# fsu-grep — a small `grep`/`rg` work-alike, to demonstrate `FsUtils::Grep`.
#
# Familiar short flags keep their usual meaning; anything this shard invented
# gets a long name only.

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

parser = OptionParser.new do |o|
  o.banner = "Usage: fsu-grep PATTERN [ROOT...] [options]"

  o.on("-i", "--ignore-case", "Case-insensitive matching") { ignore_case = true }
  o.on("-F", "--fixed-strings", "Treat the pattern literally, not as a regex") { fixed_string = true }
  o.on("-l", "--files-with-matches", "Print each matching file once, not every line") do
    mode = FsUtils::Grep::Mode::Paths
  end
  o.on("-t TYPE", "--type TYPE", "Restrict to a named file type, e.g. cr, py (repeatable)") { |v| types << v }

  o.separator "\nNot from grep(1):"
  o.on("--include GLOB", "Only search files matching GLOB (repeatable)") { |v| includes << v }
  o.on("--exclude GLOB", "Skip files matching GLOB (repeatable)") { |v| excludes << v }
  o.on("--hidden", "Search dotfiles and dot-directories") { include_hidden = true }
  o.on("--follow", "Follow symlinked directories") { follow = true }
  o.on("--max-depth N", "Do not descend below N (default 25)") { |v| max_depth = v.to_i }
  o.on("--max-matches N", "Stop after N matches (default 1000)") { |v| max_matches = v.to_i }
  o.on("--per-file N", "Matches any one file may contribute (default 20)") { |v| per_file = v.to_i }
  o.on("--per-dir N", "Matches any one directory may contribute (default 100)") { |v| per_dir = v.to_i }
  o.on("--timeout SECONDS", "Give up after SECONDS (default 10)") { |v| timeout = v.to_f }
  o.on("--types", "List the known type names and exit") do
    puts FsUtils::Grep::TYPES.keys.sort!.join(", ")
    exit 0
  end
  o.on("-q", "--quiet", "Suppress the trailing report") { quiet = true }

  o.on("-h", "--help", "Show this help") do
    puts o
    exit 0
  end

  o.unknown_args do |args|
    pattern = args.shift?
    roots = args
  end
  o.invalid_option { |flag| abort "fsu-grep: #{flag}\n#{o}" }
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
rescue ex : FsUtils::Error
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

report = grep.run do |m|
  if mode.paths?
    puts m.relative_path.colorize(:cyan)
  else
    print m.relative_path.colorize(:cyan)
    print ":".colorize(:dark_gray)
    print m.line_number.colorize(:yellow)
    print ":".colorize(:dark_gray)
    print m.column.colorize(:yellow)
    print ": ".colorize(:dark_gray)
    print highlight(m.line, m.column, m.matched)
    puts m.truncated_line? ? " …".colorize(:dark_gray) : ""
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
