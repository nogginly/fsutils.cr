require "option_parser"
require "../src/fsutils"

# fsu-fetch-as-md -- fetches a URL and prints it as Markdown, to demonstrate
# the `fetch_as_markdown` tool against real sites, which no hand-written
# fixture stands in for.
#
# Goes through `FsUtils::Tools` rather than the helpers underneath, so a run
# exercises what the tool actually does: the host guard, the three content
# classes, the size bounds, and the spill to the scratch area.

def to_int(flag : String, value : String) : Int32
  value.to_i? || abort("fsu-fetch-as-md: #{flag} expects a whole number, got #{value.inspect}")
end

url = nil.as(String?)
root = "."
config = FsUtils::Tools::Config.new

OptionParser.parse do |parser|
  parser.banner = "usage: fsu-fetch-as-md [options] URL"
  parser.on("-C DIR", "--root DIR", "workspace root; a spilled page is written under it") { |value| root = value }
  parser.on("--max-output-bytes BYTES", "above this the page is written instead of printed") do |value|
    config.max_output_bytes = to_int("--max-output-bytes", value)
  end
  parser.on("--max-page-bytes BYTES", "cap on bytes read from the response") do |value|
    config.fetch.max_page_bytes = to_int("--max-page-bytes", value).to_i64
  end
  parser.on("--max-content-bytes BYTES", "cap on the Markdown produced") do |value|
    config.fetch.max_content_bytes = to_int("--max-content-bytes", value).to_i64
  end
  parser.on("--allow-private", "permit loopback and private addresses") { config.fetch.allow_private_hosts = true }
  parser.on("-h", "--help", "show this help") do
    puts parser
    exit
  end
  parser.unknown_args { |args| url = args.first? }
end

target = url
abort("fsu-fetch-as-md: a URL is required") if target.nil?

response = FsUtils::Tools.new(root, config).fetch_as_markdown(target)

unless response.ok?
  error = response.error
  abort("fsu-fetch-as-md: #{error.try(&.message)}#{error.try(&.suggestion).try { |advice| "\n  #{advice}" }}")
end

STDERR.puts "#{response.url} -> #{response.status} #{response.content_type}, #{response.bytes} bytes#{response.truncated ? ", truncated" : ""}"
STDERR.puts "  #{response.notice}" if response.notice

if content = response.content
  puts content
else
  STDERR.puts "  written to #{response.path}, #{response.lines} lines"
  response.toc.try(&.each do |heading|
    puts "#{"  " * (heading.level - 1)}#{heading.title} [#{heading.start_line}-#{heading.end_line}]"
  end)
end
