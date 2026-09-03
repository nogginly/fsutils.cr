# `FsUtils::Find` — design

A `find(1)`-flavoured directory walker, built to be driven by an AI agent rather
than by a human at a prompt. The difference matters: an agent cannot see a
runaway scan, cannot press Ctrl-C, and will happily paste 40,000 paths into its
own context. The design therefore assumes every scan is bounded, and that
*telling the caller it was bounded* is part of the result.

Zero runtime dependencies; stdlib only.

## Shape

```crystal
find = FsUtils::Find.new("src", name: ["*.cr"], max_matches: 200)
report = find.run do |m|
  puts "#{m.path} (#{m.size} bytes)"
end
report.truncated? # => did we stop early, and why
```

`run` yields a `Match` record and returns a `Report`. Nothing is buffered: the
block sees each hit as it is found, so memory is O(frontier), not O(results).

### `Match`

`path`, `name`, `type` (file / directory / symlink / other), `size`,
`modification_time`, `depth`, `symlink?`. A record rather than a tuple, so
fields can be added later without breaking callers.

### `Report`

`matches`, `scanned`, `directories`, `pruned` (dirs deliberately not entered),
`errors`, `elapsed`, and `stop_reason`. The stop reason is the point: an agent
that receives `MaxMatches` knows to narrow its query rather than conclude the
file does not exist.

## Traversal: breadth-first, on purpose

`find(1)` is depth-first, which is exactly wrong here. Depth-first plus a match
limit means the first deep directory you stumble into eats the entire budget —
`node_modules` wins, your source tree never gets looked at.

Breadth-first spends the budget level by level, so results are spread across the
tree. Combined with `max_matches_per_dir`, a single fat directory can contribute
at most its quota and is then skipped for matching purposes (its children are
still queued). Think of it as a buffet with a serving spoon rather than a queue
of people with buckets.

## Guard rails

Five independent brakes, each with a sane default:

Limit                |Default|Stops                        
---------------------|-------|-----------------------------
`max_matches`        |1_000  |Context blow-out             
`max_matches_per_dir`|100    |One directory dominating     
`max_entries_scanned`|100_000|Needle-free haystacks        
`max_seconds`        |10.0   |Network mounts, spinning rust
`max_depth`          |32     |Pathological nesting         

Plus `skip_dirs`, a default deny-list of the usual sinkholes (`.git`,
`node_modules`, `lib`, `.venv`, `target`, `vendor`, `__pycache__`, …). Pass
`skip_dirs: [] of String` to disable.

Errors — unreadable directories, vanished files — are collected, never raised.
A permissions hiccup halfway through a scan should degrade the result, not
destroy it.

## Symlinks and loops

Default is `follow_symlinks: false`: symlinks are reported (and matchable via
`type: :symlink`) but never descended. This alone makes cycles impossible.

With `follow_symlinks: true`, every directory is resolved with `File.realpath`
before it is entered, and the real path is recorded in a `Set(String)`. A second
visit is pruned. This also deduplicates overlapping roots (`["src", "src/."]`)
for free. `realpath` costs a syscall per directory, which is noise next to the
`readdir` it precedes.

## Matching

- `name:` globs match the basename; `path:` globs match the full path;
  `exclude:` globs match either. All are OR-ed within a list, AND-ed across
  lists. Empty list means "no opinion".
- `case_insensitive:` downcases both sides. Crude, correct for ASCII, good
  enough for filenames.
- Filters: `type`, `min_size`/`max_size`, `newer_than`/`older_than`,
  `min_depth`, `include_hidden`.

## Deliberate omissions

No `-exec`, no boolean expression grammar, no `-printf`. An agent composing
shell fragments is a hazard; a typed constructor is not. Content search belongs
in the sibling `Grep` helper, which will share this traversal core once its
shape settles.

## Determinism

Children are sorted before queueing. Two runs over an unchanged tree produce
identical output — which makes the spec possible and makes agent behaviour
reproducible.
