module FsUtils
  class Tools
    # The name each tool is registered under.
    #
    # Single-sourced because the descriptions cross-reference one another, and
    # a description naming a tool the host did not register is worse than no
    # description at all. The names are fixed: this shard has no prefixing
    # hook, which is recorded in DESIGN.md as a constraint rather than left to
    # be discovered.
    module Names
      FIND        = "find_files"
      GREP        = "search_file_contents"
      READ        = "read_text_file"
      WRITE       = "write_text_file"
      REPLACE     = "text_replace"
      FETCH_AS_MD = "fetch_as_markdown"

      ALL = [FIND, GREP, READ, WRITE, REPLACE, FETCH_AS_MD]
    end

    # One tool, as the parts a host actually needs.
    #
    # Deliberately not a protocol-shaped blob. Anthropic spells the parameter
    # schema `input_schema` where OpenAI and Gemini spell it `parameters`, so
    # any bundled form is one vendor's. Assembling one from these is string
    # interpolation; taking one apart is parsing, which is the direction that
    # goes wrong.
    #
    # That objection is to protocol shape, not to size, which is why
    # `capabilities` belongs here: it is a vendor-neutral fact about the tool,
    # in the same category as its name, and every host needs it for the same
    # reason. It is not registered with the model; it is what a host consults
    # before deciding whether to register the tool at all.
    #
    # ```
    # tools.definitions.each do |tool|
    #   next if tool.capabilities.workspace_write? && no_edit
    #   host.register(tool.name, tool.description, tool.schema)
    # end
    # ```
    #
    # `schema` is a JSON object with `type`, `properties` and `required`, and
    # nothing outside the subset Gemini and OpenAI strict mode accept -- no
    # `$ref`, no `oneOf`, no `format`. Note that `search_file_contents` has a
    # property *named* `pattern`; it is an argument, not the JSON Schema
    # keyword.
    struct Definition
      getter name : String
      getter description : String
      getter schema : String

      # What the tool touches. See `Capability`.
      getter capabilities : Capability

      def initialize(@name : String, @description : String, @schema : String,
                     @capabilities : Capability)
      end
    end

    # Builds the definitions for a given configuration.
    #
    # The schemas are the documentation a model actually reads, so the limits
    # they state have to be the limits in force. They were fixed text, which
    # was true until `Config` let a host change the numbers underneath them --
    # a schema promising a default of 200 while the host has set 20 sends a
    # model confidently at a boundary that is not there.
    #
    # Most callers want `Tools#definitions`, which passes its own config.
    module Definitions
      extend self

      # Every tool, in a stable order.
      def all(config : Config = Config.new) : Array(Definition)
        [find(config), grep(config), read(config), write(config), replace(config), fetch_as_md(config)]
      end

      # The `find` tool, as this configuration bounds it.
      def find(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::FIND,
          description: "Find files and directories by name, path, type, depth or size. Breadth-first and bounded: shallow results arrive before deep ones, and every search has caps. Check `truncated` and `notice` — a short result may be a sample, not the whole answer. At most #{config.find.max_entries_scanned} entries are examined per search. All paths are relative to the workspace root; paths outside it are refused.",
          capabilities: Capability::WorkspaceRead,
          schema: <<-JSON
            {
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
                  "description": "Do not descend below this depth. Default #{config.find.max_depth}."
                },
                "max_matches": {
                  "type": "integer",
                  "description": "Stop after this many matches. Default #{config.find.max_matches}."
                },
                "include_hidden": {
                  "type": "boolean",
                  "description": "Search dotfiles and dot-directories. Default #{config.find.include_hidden?}."
                },
                "timeout_seconds": {
                  "type": "number",
                  "description": "Give up after this long. Default #{config.find.timeout_seconds}."
                }
              },
              "required": []
            }
            JSON
        )
      end

      # The `grep` tool, as this configuration bounds it.
      def grep(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::GREP,
          description: "Search file contents by regular expression. Binary files, files over #{config.grep.max_file_bytes} bytes and the usual noise directories (.git, node_modules, vendor, build) are skipped automatically. Bounded: check `truncated` and `notice`, because a short result may be a sample. Use mode \"paths\" first when the question is which files mention something — it is far cheaper than reading every matching line. All paths are relative to the workspace root; paths outside it are refused.",
          capabilities: Capability::WorkspaceRead,
          schema: <<-JSON
            {
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
                  "description": "Stop after this many matches, or files in \\"paths\\" mode. Default #{config.grep.max_matches}."
                },
                "max_matches_per_file": {
                  "type": "integer",
                  "description": "Matches any one file may contribute, so a single noisy file cannot fill the result. Default #{config.grep.max_matches_per_file}."
                },
                "max_depth": {
                  "type": "integer",
                  "description": "Do not descend below this depth. Default #{config.grep.max_depth}."
                },
                "include_hidden": {
                  "type": "boolean",
                  "description": "Search dotfiles and dot-directories. Default #{config.grep.include_hidden?}."
                },
                "timeout_seconds": {
                  "type": "number",
                  "description": "Give up after this long. Default #{config.grep.timeout_seconds}."
                }
              },
              "required": ["pattern"]
            }
            JSON
        )
      end

      # The `read` tool, as this configuration bounds it.
      def read(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::READ,
          description: "Read a text file, whole or by line range. Output is line-numbered by default so you can cite regions back to #{Names::GREP} or a follow-up read without recounting. Check `truncated`: a long file returns its first page plus a notice telling you how to continue. `total_lines` is always the file's real length, so you can tell how much you have not seen. A page is capped at #{config.read.max_bytes} bytes however many lines you ask for, and files over #{config.read.max_file_bytes} bytes are refused outright. All paths are relative to the workspace root.",
          capabilities: Capability::WorkspaceRead,
          schema: <<-JSON
            {
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
                  "description": "Maximum lines to return. Omit for the default of #{config.read.default_limit}. Note: when you give an explicit offset or limit and the range is too large to return, the call fails rather than silently returning less."
                },
                "line_numbers": {
                  "type": "boolean",
                  "description": "Prefix each line with its number. Default true. Set false only when you need the file's exact bytes."
                }
              },
              "required": ["path"]
            }
            JSON
        )
      end

      # The `write` tool, as this configuration bounds it.
      def write(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::WRITE,
          description: "Create a text file, or replace one in full. Writes exactly what you supply — no trailing newline is added and nothing is normalised. Replacing an existing file requires overwrite: true, and the call is refused otherwise so a file you did not know was there cannot be destroyed. Missing parent directories are created and reported back; an unexpected entry in parents_created usually means a mistyped path. For a partial change use #{Names::REPLACE} instead. Content over #{config.write.max_content_bytes} bytes is refused. All paths are relative to the workspace root.",
          capabilities: Capability::WorkspaceWrite,
          schema: <<-JSON
            {
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
            JSON
        )
      end

      # The `replace` tool, as this configuration bounds it.
      def replace(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::REPLACE,
          description: "Replace a literal string in a text file. Matching is exact — no regular expressions, no fuzzy matching — including all whitespace and indentation, so copy the text from a read of the file rather than retyping it. By default old_string must occur exactly once; if it occurs several times the call is refused and every location is reported, so extend old_string with surrounding context or set replace_all. The result returns each change in context -- at most #{config.replace.max_hunks} of them -- so you can confirm it landed where you meant without reading the file again. Files over #{config.replace.max_file_bytes} bytes are refused. All paths are relative to the workspace root.",
          capabilities: Capability::WorkspaceRead | Capability::WorkspaceWrite,
          schema: <<-JSON
            {
              "type": "object",
              "properties": {
                "path": {
                  "type": "string",
                  "description": "File to edit, relative to the workspace root."
                },
                "old_string": {
                  "type": "string",
                  "description": "Exact literal text to find, whitespace included. Must not be empty."
                },
                "new_string": {
                  "type": "string",
                  "description": "Replacement text. May be empty, which deletes the matched text. Must differ from old_string."
                },
                "replace_all": {
                  "type": "boolean",
                  "description": "Replace every occurrence. Default false, which asserts there is exactly one and refuses otherwise. Use true for a rename, where the count does not matter."
                }
              },
              "required": ["path", "old_string", "new_string"]
            }
            JSON
        )
      end

      # The `fetch_as_markdown` tool, as this configuration bounds it.
      def fetch_as_md(config : Config = Config.new) : Definition
        Definition.new(
          name: Names::FETCH_AS_MD,
          description: "Fetch a URL and return it as Markdown. An HTML page is converted to Markdown; a site that serves Markdown is used as it is; any other text -- CSV, JSON, XML, CSS, SVG, plain text -- is returned inside a fenced code block tagged with its type. Short results are returned in `content`. A longer one is written to a file in the workspace and its location and content are described instead, including an excerpt and a `toc` whose line numbers go to #{Names::READ} as `offset` and `limit`. A stored file opens with a front matter block naming the page it came from. Check `truncated` and `notice`: content over #{config.fetch.max_content_bytes} bytes is cut short. Only text is read.",
          capabilities: Capability::Network | Capability::ScratchWrite,
          schema: <<-JSON
            {
              "type": "object",
              "properties": {
                "url": {
                  "type": "string",
                  "description": "Absolute http or https URL of the page to fetch."
                }
              },
              "required": ["url"]
            }
            JSON
        )
      end
    end
  end
end
