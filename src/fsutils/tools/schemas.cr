module FsUtils
  class Tools
    # Tool definitions, ready to register with a model host.
    #
    # These ship with the implementation because the schema is the
    # documentation a model actually reads. A description that drifts from the
    # code is worse than no description: it produces confident, wrong calls.
    # Limits and their defaults are stated explicitly for the same reason.

    FIND_SCHEMA = <<-JSON
      {
        "name": "find_files",
        "description": "Find files and directories by name, path, type, depth or size. Breadth-first and bounded: shallow results arrive before deep ones, and every search has caps. Check `truncated` and `notice` — a short result may be a sample, not the whole answer. All paths are relative to the workspace root; paths outside it are refused.",
        "input_schema": {
          "type": "object",
          "properties": {
            "paths": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Directories or files to search. Defaults to the workspace root."
            },
            "name": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Globs matched against the basename, e.g. \\"*.cr\\". Combined with OR."
            },
            "path": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Globs matched against the whole path. A single * does not cross a /, so these usually want a leading **/, e.g. \\"**/spec/*.cr\\"."
            },
            "exclude": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Globs that drop a match, tested against both the name and the path. Beats `name` and `path`."
            },
            "type": {
              "type": "string",
              "enum": ["file", "directory", "symlink"],
              "description": "Restrict to one entry kind."
            },
            "min_depth": {
              "type": "integer",
              "description": "Ignore entries shallower than this. The workspace root is depth 0. Default 0."
            },
            "max_depth": {
              "type": "integer",
              "description": "Do not descend below this depth. Default 32."
            },
            "max_matches": {
              "type": "integer",
              "description": "Stop after this many matches. Default 200."
            },
            "include_hidden": {
              "type": "boolean",
              "description": "Search dotfiles and dot-directories. Default false."
            },
            "timeout_seconds": {
              "type": "number",
              "description": "Give up after this long. Default 10."
            }
          },
          "required": []
        }
      }
      JSON

    READ_SCHEMA = <<-JSON
      {
        "name": "read_text_file",
        "description": "Read a text file, whole or by line range. Output is line-numbered by default so you can cite regions back to search_file_contents or a follow-up read without recounting. Check `truncated`: a long file returns its first page plus a notice telling you how to continue. `total_lines` is always the file's real length, so you can tell how much you have not seen. All paths are relative to the workspace root.",
        "input_schema": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "File to read, relative to the workspace root."
            },
            "offset": {
              "type": "integer",
              "description": "First line to return, 1-based, matching the numbering in the output. Omit to start at the beginning."
            },
            "limit": {
              "type": "integer",
              "description": "Maximum lines to return. Omit for the default of 2000. Note: when you give an explicit offset or limit and the range is too large to return, the call fails rather than silently returning less."
            },
            "line_numbers": {
              "type": "boolean",
              "description": "Prefix each line with its number. Default true. Set false only when you need the file's exact bytes."
            }
          },
          "required": ["path"]
        }
      }
      JSON

    WRITE_SCHEMA = <<-JSON
      {
        "name": "write_text_file",
        "description": "Create a text file, or replace one in full. Writes exactly what you supply — no trailing newline is added and nothing is normalised. Replacing an existing file requires overwrite: true, and the call is refused otherwise so a file you did not know was there cannot be destroyed. Missing parent directories are created and reported back; an unexpected entry in parents_created usually means a mistyped path. For a partial change use text_replace instead. All paths are relative to the workspace root.",
        "input_schema": {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "File to write, relative to the workspace root."
            },
            "content": {
              "type": "string",
              "description": "Full contents of the file. May be empty, which writes an empty file."
            },
            "overwrite": {
              "type": "boolean",
              "description": "Permits replacing an existing file. Default false. Ignored when the path does not exist. Check `created` in the result: false means you replaced something."
            }
          },
          "required": ["path", "content"]
        }
      }
      JSON

    GREP_SCHEMA = <<-JSON
      {
        "name": "search_file_contents",
        "description": "Search file contents by regular expression. Binary files, oversized files and the usual noise directories (.git, node_modules, vendor, build) are skipped automatically. Bounded: check `truncated` and `notice`, because a short result may be a sample. Use mode \\"paths\\" first when the question is which files mention something — it is far cheaper than reading every matching line. All paths are relative to the workspace root; paths outside it are refused.",
        "input_schema": {
          "type": "object",
          "properties": {
            "pattern": {
              "type": "string",
              "description": "Regular expression to search for. Set fixed_string if you mean it literally."
            },
            "paths": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Directories or files to search. Defaults to the workspace root."
            },
            "mode": {
              "type": "string",
              "enum": ["lines", "paths"],
              "description": "\\"lines\\" returns every matching line. \\"paths\\" returns each matching file once, with its first hit. Default \\"lines\\"."
            },
            "ignore_case": {
              "type": "boolean",
              "description": "Case-insensitive matching. Default false."
            },
            "fixed_string": {
              "type": "boolean",
              "description": "Treat the pattern as a literal string, not a regex. Default false."
            },
            "types": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Named file types to restrict to, e.g. \\"cr\\", \\"py\\", \\"web\\". Cheaper and less error-prone than hand-written globs."
            },
            "include_globs": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Only search files matching these globs, tested against the name and the relative path."
            },
            "exclude_globs": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Skip files matching these globs. Beats include_globs."
            },
            "max_matches": {
              "type": "integer",
              "description": "Stop after this many matches, or files in \\"paths\\" mode. Default 200."
            },
            "max_matches_per_file": {
              "type": "integer",
              "description": "Matches any one file may contribute, so a single noisy file cannot fill the result. Default 20."
            },
            "max_depth": {
              "type": "integer",
              "description": "Do not descend below this depth. Default 25."
            },
            "include_hidden": {
              "type": "boolean",
              "description": "Search dotfiles and dot-directories. Default false."
            },
            "timeout_seconds": {
              "type": "number",
              "description": "Give up after this long. Default 10."
            }
          },
          "required": ["pattern"]
        }
      }
      JSON
  end
end
