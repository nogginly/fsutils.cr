require "./fsutils/error"
require "./fsutils/text"
require "./fsutils/walker"
require "./fsutils/find"
require "./fsutils/grep"
require "./fsutils/reader"
require "./fsutils/writer"
require "./fsutils/replacer"
require "./fsutils/outline"
require "./fsutils/web/host_policy"
require "./fsutils/web/fetcher"
require "./fsutils/web/html_to_markdown"

require "./fsutils/tools"

module FsUtils
  # :nodoc:
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
