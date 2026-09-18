require "option_parser"
require "../src/fsutils"

# fsu-fetch -- fetches a page and prints it as Markdown, to demonstrate
# `FsUtils::Web::Fetcher` and `FsUtils::Web::HtmlToMarkdown` against real
# sites, which no hand-written fixture can stand in for.

def to_int(flag : String, value : String) : Int32
  value.to_i? || abort("fsu-fetch: #{flag} expects a whole number, got #{value.inspect}")
end

url = nil.as(String?)
max_page_bytes = FsUtils::Web::Fetcher::DEFAULT_MAX_PAGE_BYTES
max_markdown_bytes = nil.as(Int32?)
allow_private = false
outline = false

OptionParser.parse do |parser|
  parser.banner = "usage: fsu-fetch [options] URL"
  parser.on("--max-page-bytes BYTES", "cap on bytes read from the response") do |value|
    max_page_bytes = to_int("--max-page-bytes", value)
  end
  parser.on("--max-markdown-bytes BYTES", "cap on Markdown written") do |value|
    max_markdown_bytes = to_int("--max-markdown-bytes", value)
  end
  parser.on("--allow-private", "permit loopback and private addresses") { allow_private = true }
  parser.on("--outline", "print the heading outline instead of the page") { outline = true }
  parser.on("-h", "--help", "show this help") do
    puts parser
    exit
  end
  parser.unknown_args do |args|
    url = args.first?
  end
end

target = url
abort("fsu-fetch: a URL is required") if target.nil?

fetcher = FsUtils::Web::Fetcher.new do |settings|
  settings.max_page_bytes = max_page_bytes.to_i64
  settings.host_policy.allow_private_hosts = allow_private
end

begin
  page = fetcher.fetch(target)
  markdown = IO::Memory.new
  result = FsUtils::Web::HtmlToMarkdown.translate(
    IO::Memory.new(page.html), markdown,
    base_url: page.url,
    max_bytes: max_markdown_bytes.try(&.to_i64))

  STDERR.puts "#{page.url} -> #{page.status}, #{page.bytes} bytes in, #{result.bytes} bytes out#{result.truncated? ? ", truncated" : ""}"

  if outline
    FsUtils::Outline.of(markdown.to_s).headings.each do |heading|
      puts "#{"  " * (heading.level - 1)}#{heading.title} [#{heading.start_line}-#{heading.end_line}]"
    end
  else
    puts markdown.to_s
  end
rescue ex : FsUtils::Error
  abort("fsu-fetch: #{ex.message}#{ex.suggestion.try { |advice| "\n  #{advice}" }}")
end
