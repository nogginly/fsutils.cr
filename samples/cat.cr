require "option_parser"
require "colorize"
require "../src/fsutils"

# fsu-cat — print a text file, whole or by line range, to demonstrate
# `FsUtils::Reader`.
#
# Deliberately thin. The interesting part is not the flags but what comes out
# on stderr afterwards: how much of the file you actually saw, and what to do
# about the rest.

# A bad number should be a message, not a stack trace.
def to_int(flag : String, value : String) : Int32
  value.to_i? || abort("fsu-cat: #{flag} expects a whole number, got #{value.inspect}")
end

paths = [] of String
offset : Int32? = nil
limit : Int32? = nil
line_numbers = true
quiet = false
max_bytes = FsUtils::Reader::DEFAULT_MAX_BYTES

parser = OptionParser.new do |opts|
  opts.banner = "Usage: fsu-cat FILE [options]"

  opts.on("--offset N", "First line to print, 1-based") { |v| offset = to_int("--offset", v) }
  opts.on("--limit N", "Maximum lines to print (default 2000)") { |v| limit = to_int("--limit", v) }
  opts.on("-p", "--plain", "Print raw lines, without numbers") { line_numbers = false }
  opts.on("--max-bytes N", "Byte budget for the output (default 262144)") do |v|
    max_bytes = to_int("--max-bytes", v)
  end
  opts.on("-q", "--quiet", "Suppress the trailing report") { quiet = true }

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end

  opts.unknown_args { |args| paths = args }
  opts.invalid_option { |flag| abort "fsu-cat: #{flag}\n#{opts}" }
end

parser.parse
abort "fsu-cat: no file given\n#{parser}" if paths.empty?
Colorize.enabled = STDOUT.tty?

# Copied out of the closure first: Crystal will not narrow the type of a
# variable an OptionParser block captures, so the ternary needs a fresh local.
requested_offset = offset
requested_limit = limit

result = begin
  FsUtils::Reader.new(
    paths.first,
    offset: requested_offset.nil? ? 1 : requested_offset,
    limit: requested_limit.nil? ? FsUtils::Reader::DEFAULT_LIMIT : requested_limit,
    line_numbers: line_numbers,
    max_bytes: max_bytes,
  ).read
rescue ex : FsUtils::Error
  advice = ex.suggestion
  abort advice.nil? ? "fsu-cat: #{ex.message}" : "fsu-cat: #{ex.message}\n  #{advice}"
rescue ex : ArgumentError
  abort "fsu-cat: #{ex.message}"
end

print result.content

exit 0 if quiet

STDERR.puts

if result.empty_file?
  STDERR.puts "empty file".colorize(:dark_gray)
  exit 0
end

if result.past_end?
  STDERR.puts "offset is past the end; the file has #{result.total_lines} lines".colorize(:yellow)
  exit 0
end

first = result.first_line
last = result.last_line
STDERR.puts "lines #{first}-#{last} of #{result.total_lines}".colorize(:dark_gray)

# The point of the sample: a short result and a truncated one look identical on
# stdout, and only this line tells them apart.
if result.truncated? && last
  STDERR.puts "PARTIAL view. Continue with --offset #{last + 1}.".colorize(:yellow)
end

if result.long_lines > 0
  STDERR.puts "#{result.long_lines} lines were cut at the per-line limit; \
grep may serve better than reading this file.".colorize(:yellow)
end
