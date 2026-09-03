require "option_parser"
require "colorize"
require "../src/fsutils"

# fsu-find — a small directory search tool, to demonstrate `FsUtils::Find`.
#
# Not a `find(1)` work-alike, and not trying to be: this walk is breadth-first
# and bounded, which `find(1)` is not. Flags are spelled the ordinary way.

roots = [] of String
name = [] of String
path = [] of String
exclude = [] of String
type : FsUtils::Find::EntryType? = nil
min_depth = 0
max_depth = 32
max_matches = 1_000
per_dir = 100
timeout = 10.0
include_hidden = false
follow = false
skip_dirs = FsUtils::Find::DEFAULT_SKIP_DIRS
quiet = false

parser = OptionParser.new do |o|
  o.banner = "Usage: fsu-find [ROOT...] [options]"

  o.on("--name PATTERN", "Glob matched against the basename (repeatable)") { |v| name << v }
  o.on("--path PATTERN", "Glob matched against the whole path; wants a leading **/") { |v| path << v }
  o.on("--type TYPE", "One of f, d, l") do |v|
    type = case v
           when "f" then FsUtils::Find::EntryType::File
           when "d" then FsUtils::Find::EntryType::Directory
           when "l" then FsUtils::Find::EntryType::Symlink
           else          abort "fsu-find: unknown --type #{v.inspect}; use f, d or l"
           end
  end
  o.on("--max-depth N", "Do not descend below N") { |v| max_depth = v.to_i }
  o.on("--min-depth N", "Do not report above N") { |v| min_depth = v.to_i }

  o.separator "\nNot from find(1):"
  o.on("--exclude PATTERN", "Drop matches by glob (repeatable)") { |v| exclude << v }
  o.on("--hidden", "Include dotfiles and dot-directories") { include_hidden = true }
  o.on("--follow", "Follow symlinked directories") { follow = true }
  o.on("--max-matches N", "Stop after N matches (default 1000)") { |v| max_matches = v.to_i }
  o.on("--per-dir N", "Matches any one directory may contribute (default 100)") { |v| per_dir = v.to_i }
  o.on("--timeout SECONDS", "Give up after SECONDS (default 10)") { |v| timeout = v.to_f }
  o.on("--no-skip-dirs", "Walk node_modules, .git and friends too") { skip_dirs = [] of String }
  o.on("-q", "--quiet", "Suppress the trailing report") { quiet = true }

  o.on("-h", "--help", "Show this help") do
    puts o
    exit 0
  end

  o.unknown_args { |args| roots = args }
  o.invalid_option { |flag| abort "fsu-find: #{flag}\n#{o}" }
end

parser.parse
roots = ["."] if roots.empty?
Colorize.enabled = STDOUT.tty?

find = FsUtils::Find.new(
  roots,
  name: name,
  path: path,
  exclude: exclude,
  type: type,
  min_depth: min_depth,
  max_depth: max_depth,
  max_matches: max_matches,
  max_matches_per_dir: per_dir,
  timeout: timeout.seconds,
  follow_symlinks: follow,
  include_hidden: include_hidden,
  skip_dirs: skip_dirs,
)

report = find.run do |m|
  colour = case m.type
           when .directory? then :blue
           when .symlink?   then :magenta
           else                  :default
           end
  puts m.path.colorize(colour)
end

exit 0 if quiet

# The stop reason is the interesting part: a caller who cannot tell "no more
# matches" from "I gave up" will draw the wrong conclusion from an empty tail.
STDERR.puts
STDERR.puts "#{report.matches} matches, #{report.scanned} entries scanned, #{report.directories} directories, #{report.elapsed.total_milliseconds.round(1)}ms"
  .colorize(:dark_gray)

case report.stop_reason
when .max_matches?
  STDERR.puts "stopped: max_matches — showed #{report.matches}, there may be more. \
Narrow with -name, or raise --max-matches.".colorize(:yellow)
when .max_entries_scanned?
  STDERR.puts "stopped: scanned #{report.scanned} entries without finishing. \
Narrow the root, or raise --max-matches.".colorize(:yellow)
when .timeout?
  STDERR.puts "stopped: timed out after #{timeout}s. \
Narrow the root, or raise --timeout.".colorize(:yellow)
end

if report.dirs_capped > 0
  STDERR.puts "#{report.dirs_capped} directories hit their --per-dir quota; \
results are a sample.".colorize(:yellow)
end

report.errors.first(10).each { |e| STDERR.puts "warning: #{e}".colorize(:red) }
if report.errors.size > 10
  STDERR.puts "warning: #{report.errors.size - 10} further errors omitted".colorize(:red)
end
