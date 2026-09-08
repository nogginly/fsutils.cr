require "./fsutils/error"
require "./fsutils/text"
require "./fsutils/walker"
require "./fsutils/find"
require "./fsutils/grep"
require "./fsutils/reader"
require "./fsutils/writer"
require "./fsutils/replacer"

require "./fsutils/tools"

module FsUtils
  # :nodoc:
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
