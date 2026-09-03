require "./fsutils/walker"
require "./fsutils/find"
require "./fsutils/grep"

require "./fsutils/tools/sandbox"

module FsUtils
  # :nodoc:
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
