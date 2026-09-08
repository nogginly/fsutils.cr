require "option_parser"
require "colorize"
require "../src/fsutils"

# fsu-rename — replace a literal string across a tree, previewing by default.
#
# The sample where the helpers compose: `Grep` in `Paths` mode finds the files,
# `Replacer` edits each one. That is the shape the design document argues for —
# a rename across a codebase is a sequence of single-file edits, each
# independently verifiable — and this is what verifying them looks like.
#
# Nothing is written without `--write`.

def to_int(flag : String, value : String) : Int32
  value.to_i? || abort("fsu-rename: #{flag} expects a whole number, got #{value.inspect}")
end

old_string : String? = nil
new_string : String? = nil
roots = [] of String
types = [] of String
includes = [] of String
excludes = [] of String
context = FsUtils::Replacer::DEFAULT_CONTEXT_LINES
write = false
include_hidden = false
quiet = false

parser = OptionParser.new do |opts|
  opts.banner = "Usage: fsu-rename OLD NEW [ROOT...] [options]"

  opts.on("--write", "Apply the changes. Without this, nothing is written") { write = true }
  opts.on("-t TYPE", "--type TYPE", "File type by extension, e.g. cr, py (repeatable)") { |v| types << v }
  opts.on("--include GLOB", "Only files matching GLOB (repeatable)") { |v| includes << v }
  opts.on("--exclude GLOB", "Skip files matching GLOB (repeatable)") { |v| excludes << v }
  opts.on("--context N", "Lines of context either side (default 3)") { |v| context = to_int("--context", v) }
  opts.on("--hidden", "Search dotfiles and dot-directories") { include_hidden = true }
  opts.on("-q", "--quiet", "Print only the summary") { quiet = true }

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end

  opts.unknown_args do |args|
    old_string = args.shift?
    new_string = args.shift?
    roots = args
  end
  opts.invalid_option { |flag| abort "fsu-rename: #{flag}\n#{opts}" }
end

parser.parse

needle = old_string
replacement = new_string
abort "fsu-rename: need OLD and NEW\n#{parser}" if needle.nil? || replacement.nil?
roots = ["."] if roots.empty?
Colorize.enabled = STDOUT.tty?

# Step one: which files mention it at all. Paths mode is far cheaper than
# pulling every matching line, and the lines are about to be re-read anyway.
candidates = [] of String
search = FsUtils::Grep.new(
  needle,
  roots,
  mode: FsUtils::Grep::Mode::Paths,
  fixed_string: true,
  types: types,
  include: includes,
  exclude: excludes,
  include_hidden: include_hidden,
  max_matches: 1_000,
)

report = begin
  search.run { |match| candidates << match.path }
rescue ex : FsUtils::Error
  abort "fsu-rename: #{ex.message}"
end

if candidates.empty?
  STDERR.puts "no files contain #{needle.inspect}".colorize(:dark_gray)
  exit 1
end

# Step two: edit each file, independently. One file's refusal does not stop the
# others, and each refusal names its own reason.
changed = 0
replacements = 0
refused = [] of {String, String}

candidates.each do |path|
  result = begin
    FsUtils::Replacer.new(
      path,
      needle,
      replacement,
      replace_all: true,
      context_lines: context,
      dry_run: !write,
    ).replace
  rescue ex : FsUtils::Error
    refused << {path, ex.message.to_s}
    next
  end

  changed += 1
  replacements += result.replacements

  next if quiet

  puts "#{path}".colorize(:cyan).bold
  result.hunks.each do |hunk|
    puts "  @@ #{hunk.start_line}-#{hunk.end_line} → #{hunk.start_line_after}-#{hunk.end_line_after}"
      .colorize(:dark_gray)
    hunk.before.each_line { |line| puts "  - #{line}".colorize(:red) }
    hunk.after.each_line { |line| puts "  + #{line}".colorize(:green) }
  end

  if result.hunks_omitted > 0
    puts "  … #{result.hunks_omitted} further regions not shown".colorize(:dark_gray)
  end
  puts
end

STDERR.puts "#{replacements} replacements across #{changed} files \
(#{report.files_scanned} scanned)".colorize(:dark_gray)

refused.each { |path, reason| STDERR.puts "skipped #{path}: #{reason}".colorize(:yellow) }

if write
  STDERR.puts "written".colorize(:green)
else
  STDERR.puts "DRY RUN — nothing was written. Re-run with --write to apply.".colorize(:yellow)
end

exit changed > 0 ? 0 : 1
