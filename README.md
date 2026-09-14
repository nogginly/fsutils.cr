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

### Read, write, replace

Three more helpers work on one file at a time. They do not stream — a file small
enough to edit is small enough to hold — but they are bounded in the same spirit.

```crystal
# Read a range. Line numbers are the file's own, so a slice cites correctly.
result = FsUtils::Reader.new("src/find.cr", offset: 12, limit: 20).read
result.total_lines # => 340, whatever the range returned

# Whole-file write, atomic: temp file, fsync, rename.
FsUtils::Writer.new("src/out.cr", "puts 1\n").write.created # => true

# Literal replacement, asserting one occurrence.
report = FsUtils::Replacer.new("src/find.cr", "old_name", "new_name").replace
report.hunks.first.before # => the surrounding lines, as they were
```

`Replacer` returns each change in context, sliced from the file as read and as
written, so a wrong target is visible immediately rather than several turns
later. It matches literally — no regex, no fuzzy matching — and refuses when
`old_string` occurs more than once unless `replace_all` is set.

`Writer` has no overwrite guard: it replaces whatever it is pointed at. The
guard lives in the tool layer, where the caller might be a language model.

### Guard rails

Every search is bounded by default, because the intended caller is an AI agent
that cannot see a runaway scan and pays for every result it receives. Matches,
matches per directory, matches per file, entries scanned, depth and elapsed time
all have caps; `.git`, `node_modules` and the usual sinkholes are skipped;
symlinks are not followed; hidden entries are ignored. All of it is adjustable,
and none of it raises — unreadable directories become `report.errors`, not an
exception.

Every helper takes its bounds as a `Settings` object, separate from the
arguments that say what to look for. Pass one, or amend a fresh one in a block:

```crystal
FsUtils::Grep.new("TODO", "src", types: ["cr"]) do |settings|
  settings.max_matches = 50
  settings.max_matches_per_file = 1
  settings.timeout = 2.seconds
end
```

Reads are bounded too, in bytes as well as lines: a long file returns its first
page and says so, rather than handing back something too large to use. Writes
and replacements are bounded differently — they are atomic, and they refuse
rather than half-finish.

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
tools.read(path: "src/find.cr", offset: 12, limit: 40).to_json
tools.write(path: "src/out.cr", content: "puts 1\n").to_json
tools.text_replace(path: "src/find.cr", old_string: "a", new_string: "b").to_json
```

Five tools, each with its own result shape but the same four common fields, so
a model learns the envelope once and the specifics per tool.

A host decides what those tools are allowed to do by handing `Tools.new` a
`Config`. It is YAML- and JSON-serialisable, so it can live as a section of a
larger agent configuration, and every field is optional:

```yaml
tool_config:
  max_output_bytes: 32000
  grep:
    max_matches: 100
    max_depth: 10
  write:
    max_content_bytes: 1048576
```

```crystal
config = FsUtils::Tools::Config.from_yaml(File.read("agent.yml"))
tools = FsUtils::Tools.new("/srv/project", config)
```

The configured values are defaults for the arguments a model may pass —
`max_matches` and friends — and hard limits for everything it may not, such as
the read byte budget and the write ceiling. A limit that cannot be honoured
raises from `Tools.new`, not from a tool call: a host can read a startup
failure, where a model can only read JSON.

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

Four things to know:

- **Paths are relative to the sandbox root**, going in and coming back. Anything
  resolving outside it — via `..`, an absolute path, or a symlink — is refused
  with `path_outside_sandbox` rather than followed.
- **A failure carries advice, not just a code.** `{"ok": false, "error": {...}}`
  has a `message` saying what happened and, where there is something useful to
  say, a `suggestion` saying what to do instead — a `find_files` call to locate
  a mistyped path, or `fixed_string: true` for a regex that would not compile.
- **`notice` is written for the model, not the log.** `stop_reason` states a
  fact; `notice` says what to do about it. Fields that have nothing to say are
  omitted rather than set to `null`.
- **`truncated` is the flag worth branching on.** It covers every reason the
  answer might be a sample: a budget spent, a noisy file or directory capped, or
  results dropped to fit the output size limit.

`Tools::DEFINITIONS` publishes each tool as its three parts — `name`,
`description` and `schema` — so a host can register them without hand-writing a
description that drifts from the code:

```crystal
FsUtils::Tools::DEFINITIONS.each do |tool|
  host.register(tool.name, tool.description, tool.schema)
end
```

The parts are published rather than a ready-made tool definition because every
vendor bundles them differently — Anthropic's `input_schema` is OpenAI's and
Gemini's `parameters`. Assembling the shape your protocol wants is
interpolation; taking a bundled one apart would be parsing. The schemas
themselves stay inside the dialect all three accept.

Tool names are fixed. There is no prefixing hook, because the descriptions
cross-reference each other by name and a prefix applied naively would point a
model at tools the host never registered.

See [DESIGN](./DESIGN.md) for the reasoning, and `samples/` for four small
command-line tools built on the helpers:

```sh
ops build-debug

./bin/debug/fsu-find src --name "*.cr" --max-matches 20
./bin/debug/fsu-grep TODO src -t cr
./bin/debug/fsu-cat src/find.cr --offset 40 --limit 20

# Preview a rename across the tree; nothing is written without --write.
./bin/debug/fsu-rename UnknownTool MissingTool src -t cr
```

`fsu-rename` is the one worth reading. It composes two helpers — `Grep` in
`Paths` mode to find candidate files, then `Replacer` on each — and prints
every change as a diff before touching anything, which is what the design
document means by a rename being a sequence of independently verifiable
single-file edits.

These are demonstrations rather than command-line work-alikes. `fsu-grep`
borrows `grep`'s short flags where they mean the same thing; the others spell
their own.

## Development

See [DEVELOPMENT](./DEVELOPMENT.md)

## Contributions, by invitation!

*With apologies*, at this time contributions are *by invitation only* and limited to people I know and see often.

These are early days for _FsUtils_ and I am busy with family and work.

At this time I want to work on this at a manageable pace.
