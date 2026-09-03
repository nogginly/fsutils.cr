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

### Agent tool calls

`FsUtils::Tools` wraps the helpers for use as tool calls. Where the helpers
stream, are typed, and raise on caller error, this layer buffers, serialises,
confines every path to a sandbox, and **never raises** — an exception is a stack
trace in someone's tool harness, whereas a JSON error is something a model can
read and recover from.

```crystal
tools = FsUtils::Tools.new("/srv/project")

tools.grep(pattern: "TODO", paths: ["src"], max_matches: 100).to_json
tools.find(name: ["*.cr"], type: "file").to_json
```

Every response has the same shape, so a model learns it once:

```json
{
  "ok": true,
  "results": [
    { "path": "src/find.cr", "line": 42, "column": 5, "text": "# TODO tidy this" }
  ],
  "summary": { "matches": 200, "scanned": 1180, "elapsed_ms": 91 },
  "truncated": true,
  "stop_reason": "max_matches",
  "notice": "Stopped at 200 matches; there may be more. Narrow with `include_globs` or a more specific pattern, or raise `max_matches`."
}
```

Three things to know:

- **Paths are relative to the sandbox root**, going in and coming back. Anything
  resolving outside it — via `..`, an absolute path, or a symlink — is refused
  with `path_outside_sandbox` rather than followed.
- **`notice` is written for the model, not the log.** `stop_reason` states a
  fact; `notice` says what to do about it. Fields that have nothing to say are
  omitted rather than set to `null`.
- **`truncated` is the flag worth branching on.** It covers every reason the
  answer might be a sample: a budget spent, a noisy file or directory capped, or
  results dropped to fit the output size limit.

`Tools::FIND_SCHEMA` and `Tools::GREP_SCHEMA` ship the JSON Schema for each tool,
so a host can register them without hand-writing a description that drifts from
the code.

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
