# FsUtils.cr

File system utilities (like `grep` and `find`) as Crystal helper classes for use without running shell commands.

## AI Use

See [DISCLOSURE](DISCLOSURE.md) for how I used AI for this project.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
      fsutils:
        github: nogginly/fsutils.cr
   ```

2. Run `shards install`

## Usage

Both helpers stream: the block sees each result as it is found, and `run`
returns a report saying what the walk cost and *why it stopped*. That last part
matters — an empty tail means nothing unless you can tell "no more matches"
from "I gave up".

### Find

```crystal
require "fsutils"

report = FsUtils::Find.new("src", name: ["*.cr"]).run do |m|
  puts "#{m.path} (#{m.size} bytes)"
end

report.matches     # => 12
report.stop_reason # => Completed
report.truncated?  # => false
```

### Grep

```crystal
require "fsutils"

report = FsUtils::Grep.new("TODO", "src", types: ["cr"]).run do |m|
  puts "#{m.relative_path}:#{m.line_number}:#{m.column}: #{m.line}"
end

report.stop_reason # => MaxMatches, if the budget ran out first
```

Pass `mode: FsUtils::Grep::Mode::Paths` to get one result per *file* instead of
one per line — much cheaper when the question is "which files mention this".

### Guard rails

Every search is bounded by default, because the intended caller is an AI agent
that cannot see a runaway scan and pays for every result it receives. Matches,
matches per directory, matches per file, entries scanned, depth and elapsed time
all have caps; `.git`, `node_modules` and the usual sinkholes are skipped;
symlinks are not followed; hidden entries are ignored. All of it is adjustable,
and none of it raises — unreadable directories become `report.errors`, not an
exception.

See [DESIGN](./DESIGN.md) for the reasoning, and `samples/` for two small
command-line tools built on the helpers:

```sh
ops build-debug
./bin/debug/fsu-grep TODO src -t cr
./bin/debug/fsu-find src --name "*.cr" --max-matches 20
```

## Development

See [DEVELOPMENT](./DEVELOPMENT.md)

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _FsUtils_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
