# FsUtils.cr

File system utilities (like `grep` and `find`) as Crystal helper classes for use without running shell commands, and an agent-facing tool layer over them.

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
tools.fetch_as_markdown(url: "https://example.com/docs").to_json
```

Six tools, each with its own result shape but the same four common fields, so
a model learns the envelope once and the specifics per tool.

A host decides what those tools are allowed to do by handing `Tools.new` a
`Config`. It is YAML- and JSON-serialisable, so it can live as a section of a
larger agent configuration, and every field is optional:

```yaml
tool_config:
  max_output_bytes: 32000
  reproducible: false
  grep:
    max_matches: 100
    max_depth: 10
  write:
    max_content_bytes: 1048576
  scratch:
    dir: ".agent-scratch"
  fetch:
    max_page_bytes: 8388608
    max_content_bytes: 4194304
    allow_private_hosts: false
    allowed_hosts: null
    denied_hosts: []
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

A host dispatching what a model asked for calls by name:

```crystal
response = tools.call("read_text_file", arguments)  # Hash(String, JSON::Any)
host.reply(body: response.to_json, is_error: !response.ok?)
```

It returns the response, not its serialisation, because every protocol carries
an error flag on the tool result separate from its body and a host should not
have to parse 32 KB to read one boolean. The return type is
`FsUtils::Tools::Response`, a union of the six response types. Every member
answers `ok?`, `to_json`, `notice` and `error`, so the common case needs no
`case`; narrow to a member — `SearchResponse(GrepResult)` — for a
shape-specific field such as `summary`. The union gains a member with every
tool added, so an exhaustive `case` over it is not a stable contract.

Arguments are a `Hash(String, JSON::Any)`, and the second parameter may be
omitted for a tool that needs none. If you hold a `JSON::Any`, write `.as_h`:
"these arguments are not an object" is a host bug and belongs in the host as an
exception, not in the model's error channel where nothing can act on it. The
*values* stay `JSON::Any` on purpose, so a `max_matches` of `"200"` reaches
this layer and is refused here with a suggestion the model can follow.

An unknown tool name raises `ArgumentError`: the host chose what to register,
so the host is the only one who can act on it. Wrap the call, because a model
can invent a name. Everything a model *can* fix — a parameter the tool does not
accept, a value of the wrong type, a missing required one — comes back as a
normal error response in the usual envelope. Nothing is coerced: a
`max_matches` of `"200"` is refused rather than read as 200.

The six typed methods are unchanged and remain the API for Crystal callers.

`Tools#definitions` publishes each tool as its three parts — `name`,
`description` and `schema` — so a host can register them without hand-writing a
description that drifts from the code:

```crystal
tools.definitions.each do |tool|
  host.register(tool.name, tool.description, tool.schema)
end
```

### Fetching a web page

`fetch_as_markdown` fetches an HTML page and returns it as Markdown. It is the one
tool here that leaves the machine, and the only one the sandbox cannot protect,
so it carries a guard of its own.

```crystal
response = tools.fetch_as_markdown(url: "https://example.com/docs")
response.content # the Markdown, when the page is short
response.path    # where it was written, when it is not
```

**Markdown is the container, not just the output format.** An HTML page is
converted. A site that serves Markdown is used as it is. Anything else textual —
CSV, JSON, XML, CSS, SVG, plain text — comes back verbatim inside a fenced code
block tagged with its type, because the bytes *are* the content and any
transformation would destroy them. `content_type` says which of the three
happened. The fence is always at least one backtick longer than the longest run
inside the content, so a raw README full of code blocks nests correctly rather
than closing its own fence early.

**Short pages come back whole; long ones are written to a file and described.**
A reference page converted in full can fill a small model's context on its own,
so past `max_output_bytes` the Markdown is written into the scratch directory
and the response carries `path`, `lines`, `excerpt` and `toc` instead of
`content`. Each `toc` entry gives a heading with the lines its section spans,
which are what `read_text_file` takes as `offset` and `limit` — so the index
points into a tool the model already has rather than adding a new one.

A stored file opens with YAML front matter naming the page it came from. Links
in the Markdown are root-relative where they point at the same site, which
saves a great deal on a page that links within itself and would be unresolvable
without knowing the origin. The front matter carries no timestamp, so the same
page fetched twice writes the same bytes.

**The scratch directory lives inside the workspace root**, because a path the
model cannot read back is no use to it. It is hidden, and `find` and `grep`
skip it, so a tool's own spilled output never turns up in that tool's own later
searches. Nothing prunes it; how long a page is worth keeping is the host's
question, not this shard's.

**Three bounds apply in turn, and none substitutes for another.** The fetcher
stops reading past `max_page_bytes`, counted from the response body rather than
from `Content-Length`, which is absent under chunked encoding and understates a
compressed body. `max_content_bytes` bounds what comes back whatever it is — prose is
cut back to a blank line, fenced content to a line, since a blank line means
nothing in a CSV. Fencing happens after the cut, so a truncated data file still
closes its fence. What survives is returned inline only if it fits `max_output_bytes`. A
page of boilerplate shrinks under conversion; a page of dense tables grows.

**Where it may go is checked by resolving, then comparing** — the sandbox's own
rule, applied to a host instead of a path. The name is checked against
`allowed_hosts` and `denied_hosts`, then resolved, and every address it answers
with is checked against the loopback, link-local and private ranges. A redirect
is a new URL and faces the same check, because a permitted host answering with
a redirect to `localhost` is the ordinary way an allowlist is defeated.

`allowed_hosts` is null when there is no allowlist. An empty array is an
allowlist naming nothing, and permits nothing: a list means exactly what it
contains. `denied_hosts` is the same rule read the other way, so an empty
denylist forbids nothing.

### Responses that repeat

`reproducible: true` omits the fields that report *when* or *where* a call ran,
leaving only what is derived from the tree's contents and paths. Two identical
calls then return byte-identical JSON, on any machine, from any checkout. The
list is short and is part of the contract: `summary.elapsed_ms` on both
searching tools, and `modified` on each `find_files` result. They are omitted
rather than zeroed — an `elapsed_ms` of 0.0 is a number a model may reason
about.

This is what makes a response usable as a recorded fixture, and the same
property is what lets a host cache a result against an unchanged tree or
compare two runs of an agent.

It covers fields that are volatile by construction, not by measurement. A time
budget is the latter: an identical call may stop early on a slower machine and
return less. A response whose `stop_reason` is `timeout` genuinely did
different work and the guarantee does not cover it — assert that it never
happens, and bound the walk by work rather than by clock, since `max_matches`,
`max_depth` and `max_entries_scanned` truncate identically everywhere.

The descriptions state the limits actually in force, so they are built from the
instance's configuration: set `grep.max_matches` to 20 and the schema says 20.
Registering before there is a `Tools` to ask, use
`FsUtils::Tools::Definitions.all(config)`. They are built once; if you mutate a
`Config` after construction, call `refresh_definitions`.

The parts are published rather than a ready-made tool definition because every
vendor bundles them differently — Anthropic's `input_schema` is OpenAI's and
Gemini's `parameters`. Assembling the shape your protocol wants is
interpolation; taking a bundled one apart would be parsing. The schemas
themselves stay inside the dialect all three accept.

Tool names are fixed. There is no prefixing hook, because the descriptions
cross-reference each other by name and a prefix applied naively would point a
model at tools the host never registered.

See [DESIGN](./DESIGN.md) for the reasoning, and `samples/` for five small
command-line tools built on the helpers:

```sh
ops build-debug

./bin/debug/fsu-find src --name "*.cr" --max-matches 20
./bin/debug/fsu-grep TODO src -t cr
./bin/debug/fsu-cat src/find.cr --offset 40 --limit 20

# Preview a rename across the tree; nothing is written without --write.
./bin/debug/fsu-rename UnknownTool MissingTool src -t cr

# Fetch a page as Markdown, or just its headings.
./bin/debug/fsu-fetch https://example.com/docs --outline
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
