require "./fsutils/walker"
require "./fsutils/find"
require "./fsutils/grep"

module FsUtils
  # :nodoc:
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
