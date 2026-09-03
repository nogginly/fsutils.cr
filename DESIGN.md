# FsUtils — Design

File system utilities as Crystal classes, so a program can search a tree without
shelling out. Zero runtime dependencies; stdlib only.

The shard has two audiences and they want opposite things.

A **Crystal caller** wants a stream: yield me matches as you find them, let me
decide what to keep, raise if I passed nonsense. An **AI agent** wants a
document: give me a bounded, self-describing JSON blob, never raise, and tell me
what you *didn't* show me. Trying to serve both from one class produces something
that serves neither, so the shard is two layers.

```
FsUtils::Tools   # singletons: sandboxed, buffered, JSON, never raise
      │
FsUtils::Find    FsUtils::Grep    # helpers: streaming, typed, may raise
      └──────┬──────┘
FsUtils::Walker(P)                # one bounded breadth-first traversal
FsUtils::Walk                     # the types both layers speak: Entry, Report, Policy
```

## The thesis, stated once

Every scan is bounded, and *saying that it was bounded* is part of the result.

A human who gets 40,000 hits scrolls past them. An agent cannot see a runaway
scan, cannot press Ctrl-C, pays for every result in tokens, and will then draw
confident conclusions from whatever fragment it happened to see. An agent that
cannot distinguish "there are no more matches" from "I gave up" will cheerfully
report the wrong answer. Hence: caps everywhere, a `stop_reason` on every result,
and a traversal order chosen so that an exhausted budget still yields something
useful.

---

## `FsUtils::Walker`

The traversal core. It knows about directories, budgets, cycles and clocks; it
has no opinion about what makes a match. `Find` and `Grep` are policies layered
over it.

### Generic over its policy

`Walker(P)` takes its policy as a type parameter rather than as an abstract base
class. With a concrete `P`, Crystal monomorphises and inlines the policy calls
exactly as it would a block — so the traversal-object pattern costs nothing over
the `yield` it replaces. Typing the policy as a shared parent would put a vtable
back in the inner loop for no benefit whatever.

`Walk::Policy` is therefore a *module* documenting the contract, included by
policies so the compiler checks them, but never used as a type. Policies may be
structs; they live for exactly one `run`.

```crystal
def visit(entry : Entry, limit : Int32) : Int32   # returns matches emitted
def enter_dir(dir : String, depth : Int32) : Bool # false to prune
def leave_dir(dir : String, depth : Int32) : Nil
```

`limit` is the walker's budget arithmetic made explicit:
`min(remaining directory quota, max_matches - matches so far)`, always positive.
A policy may narrow it — `Grep` applies its own per-file cap — but never exceed
it; a return above `limit` is clamped rather than trusted. A policy is free to
spend the whole limit on one entry, which is precisely what `Grep` does when a
single file yields twenty matches.

Putting the arithmetic here rather than in each helper is the point of the
exercise: the per-directory budget is the thing both helpers previously got
subtly wrong, and it now exists in one place.

### Breadth-first, on purpose

`find(1)` is depth-first, which is exactly wrong here. Depth-first plus a match
limit means the first deep directory you fall into eats the entire budget:
`node_modules` wins, your source tree is never looked at.

Breadth-first spends the budget level by level, so results spread across the top
of the tree — which is where the interesting code lives. Combined with a
per-directory quota, a single fat directory contributes at most its share and is
then skipped for matching purposes; its children are still queued. A buffet with
a serving spoon, rather than a queue of people with buckets.

Children are sorted before queueing, so two runs over an unchanged tree produce
identical output. Reproducibility is worth more to an agent, and to a spec, than
raw speed.

### Budgets

Five independent brakes, each with a default a caller gets for free:

Limit                |Default|Stops                        
---------------------|-------|-----------------------------
`max_matches`        |1_000  |Context blow-out             
`max_matches_per_dir`|100    |One directory dominating     
`max_entries_scanned`|100_000|Needle-free haystacks        
`timeout`            |10s    |Network mounts, spinning rust
`max_depth`          |32     |Pathological nesting         

Plus `skip_dirs`, one deny-list (`Walk::DEFAULT_SKIP_DIRS`) of the usual
sinkholes shared by both helpers
(`.git`, `.hg`, `.svn`, `node_modules`, `lib`, `vendor`, `.venv`, `target`,
`build`, `dist`, `__pycache__`, `.cache`, `.terraform`, `.next`). Pass
`skip_dirs: [] of String` to disable.

Errors — unreadable directories, files that vanish mid-walk — are collected in
`errors`, never raised. A permissions hiccup halfway through should degrade a
result, not destroy it.

### Symlinks and loops

Default `follow_symlinks: false`: symlinks are reported, and matchable as
`type: :symlink`, but never descended. That alone makes cycles impossible.

With `follow_symlinks: true`, each directory is resolved with `File.realpath`
before entry and recorded in a `Set(String)`; a second visit is pruned. This
deduplicates overlapping roots (`["src", "src/."]`) for free. `realpath` costs a
syscall per directory, which is noise next to the `readdir` that follows it.
`max_depth` is the belt to that pair of braces.

### The loop

```mermaid
---
config:
  layout: elk
---
flowchart TD
    A[Roots pushed onto BFS queue] --> B{{Queue empty?}}
    B -- yes --> Z[Report: Completed]
    B -- no --> C[Pop dir + depth]
    C --> D{{Budget left?<br/>scanned / timeout}}
    D -- no --> Y[Report: MaxEntriesScanned or Timeout]
    D -- yes --> E{{realpath already seen?}}
    E -- yes --> P[pruned += 1] --> B
    E -- no --> F[[Record realpath<br/>readdir, sort children<br/>dir_budget = max_matches_per_dir]]

    F --> G{{Next child?}}
    G -- none --> B
    G -- hidden, and not include_hidden --> G
    G -- yes --> H[lstat + stat]
    H --> I[Yield entry to policy]

    I --> J{{Policy matched?}}
    J -- no --> N
    J -- yes --> K{{dir_budget left?}}
    K -- no --> Q[dirs_capped += 1] --> B
    K -- yes --> L[Emit Match<br/>dir_budget -= 1]
    L --> M{{matches >= max_matches?}}
    M -- yes --> X[Report: MaxMatches]
    M -- no --> N{{Descend?<br/>dir, not in skip_dirs,<br/>depth ok, symlink policy}}
    N -- yes --> O[Enqueue child at depth + 1] --> G
    N -- no --> G

    style Z stroke:#2e7d32,stroke-width:2px
    style X stroke:#c62828,stroke-width:2px
    style Y stroke:#c62828,stroke-width:2px
    style Q stroke:#e67e22,stroke-width:2px
    style L stroke:#1565c0,stroke-width:2px
```

### `Report`

`Walk::Report` carries `matches`, `scanned`, `directories`, `pruned`,
`dirs_capped`, `errors`, `elapsed` and `stop_reason`. `truncated?` is true when
the stop reason is anything but `Completed` **or** when `dirs_capped > 0`: a
capped directory means the caller saw a sample, whatever the stop reason says.

`dirs_capped` belongs here rather than to `Grep` because `Walker` owns the
per-directory budget, and a counter should live with the thing that decrements
it. Each helper composes this record into its own report — `Grep` adds
`files_skipped` and `files_capped` — rather than inheriting from it, so neither
carries fields that mean nothing to it.

---

## `FsUtils::Find`

A `find(1)`-flavoured filter over `Walker`. Nothing is buffered: the block sees
each hit as it is found, so memory is O(frontier), not O(results).

```crystal
report = FsUtils::Find.new("src", name: ["*.cr"], max_matches: 200).run do |m|
  puts "#{m.path} (#{m.size} bytes)"
end
report.truncated? # => did we stop early, and why
```

`Match` carries `path`, `name`, `type` (file / directory / symlink / other),
`size`, `modification_time`, `depth`, `symlink?`. A record rather than a tuple,
so fields can be added without breaking callers.

**Matching.** `name:` globs match the basename; `path:` globs match the *whole*
path, so they nearly always want a leading `**/` — a single `*` does not cross a
`/`. `exclude:` matches either. Globs are OR-ed within a list and AND-ed across
lists; an empty list means "no opinion". `case_insensitive:` downcases both
sides: crude, correct for ASCII, good enough for filenames.

**Filters.** `type`, `min_size`/`max_size`, `newer_than`/`older_than`,
`min_depth`.

**Omitted deliberately.** No `-exec`, no boolean expression grammar, no
`-printf`. An agent composing shell fragments is a hazard; a typed constructor
is not. Content search belongs in `Grep`.

---

## `FsUtils::Grep`

Content search over the same traversal. Matches are yielded as found — the class
never accumulates a result array, so memory stays flat regardless of tree size.

```crystal
report = FsUtils::Grep.new("TODO", "src", max_matches: 200).run do |m|
  puts "#{m.relative_path}:#{m.line_number}:#{m.column}: #{m.line}"
end
```

`Match` carries `path`, `relative_path`, `line_number`, `column`, `line`,
`matched`, `truncated_line?`. Enough to cite a result; not so much that the
struct becomes a second file API.

### Output modes

`Mode::Lines` (default) yields one `Match` per matching line. `Mode::Paths`
yields one `Match` per *file* — the first hit — then abandons it. The
distinction is a token budget, not a formatting preference: "which files mention
`AuthToken`" is the cheap reconnaissance step, and an agent forced to pull
matching lines to learn a filename pays twenty times over for the privilege.
Early exit makes it markedly faster too.

Under `Paths`, `max_matches` counts files and `max_matches_per_file` is ignored.
The mode reinterprets the caps rather than silently dropping them, which is why
it is an enum and not a boolean flag.

### Type filters

`types: ["cr", "yaml"]` expands via the `TYPES` map into globs unioned with
`include`. Sugar, but sugar that stops a caller hand-rolling `*.{cr,ecr}` and
quietly missing half the files. Unknown names raise — a silent empty result is
the worst possible failure mode for a caller that cannot see the filesystem.

### Scanning one file

`Walker` decides *which* files are offered; `Grep` decides how much of each one
it can afford. Three caps converge on every file, and the smallest wins:

```mermaid
---
config:
  layout: elk
---
flowchart TD
    A[File offered by Walker] --> B{{"include / exclude globs<br/>size <= max_file_bytes"}}
    B -- rejected --> R[files_skipped += 1] --> Z[Return to Walker]
    B -- accepted --> C{{"Binary?<br/>NUL byte in first 8 KiB"}}
    C -- yes --> R
    C -- no --> D[["limit = min(<br/>per_file, dir_budget, max_matches - matches)<br/>per_file = 1 in Paths mode"]]
    D --> E{{"limit <= 0?"}}
    E -- yes --> Z
    E -- no --> F[Scan lines, yield Match]

    F --> G{{Which cap ran out first?}}
    G -- "global: max_matches" --> H[stop_reason = MaxMatches] --> Z
    G -- "per-file" --> I[files_capped += 1] --> J
    G -- "dir_budget" --> K[dirs_capped += 1] --> J
    G -- "none: file exhausted" --> J[dir_budget -= found] --> Z

    style H stroke:#c62828,stroke-width:2px
    style I stroke:#e67e22,stroke-width:2px
    style K stroke:#e67e22,stroke-width:2px
```

The three caps answer three different questions: *have I spent my whole budget?*
(`max_matches`), *is this one file drowning me?* (`max_matches_per_file`), and
*is this one directory drowning me?* (`max_matches_per_dir`). Each sets a
different counter, so the `Report` says which of the three actually bit.

### Additional guard rails

Risk                               |Mitigation                                                   
-----------------------------------|-------------------------------------------------------------
Binary files: noise in, garbage out|Sniff first 8 KiB for a NUL byte; skip                       
Huge files                         |`max_file_bytes`, default 5 MB                               
One 2 MB line of minified JS       |`max_line_length`, default 1000; `truncated_line?` flags it  
One lockfile matching on every line|`max_matches_per_file`, default 20; counted in `files_capped`
Pathological regex                 |Timeout checked between files and every 256 lines            
Unreadable files, races, bad UTF-8 |Rescued per file, counted in `files_skipped`, never fatal    

Only a bad pattern or a missing root raises. Everything the filesystem throws at
us is a statistic, not an exception.

### Omitted deliberately

No context lines (`-A`/`-B`/`-C`), no `-v`, no parallelism, no `.gitignore`
parsing, no multiline patterns. Context lines in particular change the shape of
`Match` and decouple *matches* from *lines yielded*, at which point `Report`
needs a `lines_yielded` counter so a caller can see what it actually spent.
Each is easy to bolt on later; none is needed to make the tool useful.

---

## Shared vocabulary

Both helpers use one set of names and defaults, because an agent that has learned
one tool should not be ambushed by the next.

Concept           |Decision                                                                
------------------|------------------------------------------------------------------------
Result object     |`Walk::Report`, composed into each helper's own; `truncated?`           
Why we stopped    |`StopReason` — `Completed`, `MaxMatches`, `MaxEntriesScanned`, `Timeout`
Roots             |`Array(String)`, with a single-`String` convenience overload            
Hidden entries    |`include_hidden: false` — agents rarely want dotfile churn              
Time limit        |`timeout : Time::Span`                                                  
Skip list         |one `Walk::DEFAULT_SKIP_DIRS`                                           
Failure           |`FsUtils::Error`; `ArgumentError` reserved for genuine programmer error 
Filesystem trouble|collected into `errors`, never raised                                   

A helper instance is single-use per `run` and not thread-safe. Spawn a new one.

---

## `FsUtils::Tools`

The agent-facing layer: module-level singletons that call a helper, buffer the
results, and serialise them. No state between calls, so plain module methods
rather than classes — `Tools.grep(...)` reads better at the call site than
`Tools::Grep.call(...)`.

```crystal
tools = FsUtils::Tools.new(root: "/srv/project")
json  = tools.grep(pattern: "TODO", path: "src", max_matches: 100)
```

Arguments are flat and JSON-friendly — strings, ints, string arrays; no
`Time::Span`, no enums — because they arrive from a model as JSON in the first
place. Each method returns a `JSON::Serializable` struct with a `to_json`, so a
caller wanting the object is not forced to re-parse the string.

### The sandbox

**This layer refuses to leave its root.** The helpers are for trusted local
callers and take you wherever you point them; the tool layer assumes its caller
is a language model that may have read `../../.ssh/id_rsa` in a prompt somewhere
and thought it looked interesting.

The rule is: resolve, then compare — never validate the string before resolving
it, because `..` and symlinks both launder a string past a naive prefix check.

```mermaid
---
config:
  layout: elk
---
flowchart TD
    A[Requested path from agent] --> B{{Absolute?}}
    B -- yes --> C[Use as-is]
    B -- no --> D[Join onto sandbox root]
    C --> E[File.expand_path]
    D --> E
    E --> F{{Path exists?}}
    F -- no --> G[Walk up to nearest existing ancestor]
    F -- yes --> H[File.realpath]
    G --> H
    H --> I{{"realpath == root, or<br/>starts with root + separator?"}}
    I -- no --> X["ok: false<br/>error: path_outside_sandbox"]
    I -- yes --> Y[Proceed]

    style X stroke:#c62828,stroke-width:2px
    style Y stroke:#2e7d32,stroke-width:2px
```

Three details that matter:

- **The separator check is not optional.** A bare `starts_with?(root)` lets
  `/srv/project-secrets` pass for root `/srv/project`. The same bug currently
  lurks in `Grep#relative`, which is what drew attention to it.
- **Resolve before comparing, and resolve the nearest *existing* ancestor** when
  the path itself does not exist, so a lookup of a missing file inside the
  sandbox is a clean "not found" rather than a resolution error.
- **`follow_symlinks` is forced off** unless the caller explicitly enables it,
  and even then every resolved directory is re-checked against the root. A
  symlink inside the sandbox pointing out of it is the obvious escape.

Paths in the response are returned relative to the sandbox root. The agent never
sees the absolute layout of the host, which is both a small security win and a
meaningful token saving.

### The envelope

One shape for every tool, so an agent learns it once:

```json
{
  "ok": true,
  "results": [ ],
  "summary": { "matches": 42, "scanned": 1180, "elapsed_ms": 91 },
  "truncated": true,
  "stop_reason": "max_matches",
  "notice": "Stopped at 42 matches; there may be more. Narrow with `include` or a more specific pattern.",
  "errors": ["src/vendor: permission denied"],
  "errors_omitted": 0
}
```

Four things earn their place:

- **`notice`** is prose aimed at the model. `stop_reason: "max_matches"` is a
  fact; "narrow your query" is an action, and models act on the latter far more
  reliably than they reason from the former.
- **`ok: false` with an `error` object, never an exception.** A raised Crystal
  exception becomes a stack trace in someone's tool harness. A JSON error is
  something the model can read and recover from. Error codes are a closed set:
  `path_outside_sandbox`, `path_not_found`, `invalid_pattern`, `invalid_argument`.
- **`errors` is capped** at ten with an `errors_omitted` count. Otherwise a walk
  across a permissions-denied mount becomes the entire response.
- **`max_output_bytes`**, a limit that exists only at this layer. Grep lines vary
  wildly; 200 matches may be 2 KB or 200 KB, and `max_matches` cannot tell the
  difference. Results are truncated when the serialised size would exceed it, and
  `truncated` is set with a `notice` that says so.

### Tool schemas

Each tool ships its JSON Schema as a constant — `Tools::FIND_SCHEMA`,
`Tools::GREP_SCHEMA` — so a host can register the tool without hand-writing a
description that drifts from the implementation. The schema is the documentation
the model actually reads, so limits and their defaults are described in it
explicitly.

---

## Roadmap

Settled: `Walker` extraction, then `Find`/`Grep` rebased on it, then `Tools`.

Candidates after that, roughly in order of usefulness to an agent: bounded file
read with line ranges; `ls` with metadata; `tree` with a depth cap; and only
then anything that writes. Write tools inside a sandbox are a different
conversation, and a longer one.
