module FsUtils
  class Tools
    # What a tool touches, so a host offering a restricted mode does not have
    # to keep a table of tool names in step with this shard.
    #
    # Every host that offers "read but do not edit" or "no egress" needs the
    # same answer, and it is an answer about the tool rather than about the
    # host's policy: whether `text_replace` writes is a fact, and two hosts
    # that disagree are not exercising taste. A host also cannot infer it from
    # the name -- nothing in `fetch_as_markdown` says it spills large pages
    # into a directory on disk.
    #
    # ```
    # tools.definitions.reject { |tool| tool.capabilities.workspace_write? }
    # ```
    #
    # These say what a tool *touches*, never what it is *permitted*. A host's
    # configuration changes what the schemas say, not what a tool does, so
    # `fetch_as_markdown` still declares `Network` under an empty host
    # allowlist that will refuse every URL. Which capabilities to allow is the
    # host's question, and this shard has no standing in it.
    @[Flags]
    enum Capability
      # Uses workspace file content as input to its answer.
      #
      # The test is whether content read off disk reaches the caller or shapes
      # the result, not whether a file was opened. `write_text_file` therefore
      # does not declare it -- it reports a path and a byte count and nothing
      # of what was there -- while `text_replace` does, because its hunks
      # carry the surrounding lines back.
      WorkspaceRead

      # Changes files the user owns.
      #
      # The capability an operator protecting their work is actually gating
      # on. Separate from `ScratchWrite` by ownership rather than location:
      # both write inside the workspace, but only this one touches a file
      # somebody else wrote.
      WorkspaceWrite

      # Writes only inside the scratch directory, which the tool created.
      #
      # Its own capability so a no-edit run can still spill. A tool that
      # cannot store a page too large to inline loses the most useful thing it
      # does, and nothing the user wrote is at risk either way.
      ScratchWrite

      # Leaves the machine.
      #
      # Not divided into reading and writing, because the division is not
      # knowable from here: a GET may change a server and this shard cannot
      # tell. It is orthogonal to the file capabilities -- a tool may leave
      # the machine and touch no file, and a hypothetical `upload` would
      # declare `WorkspaceRead | Network`, which names both ends of what it
      # does.
      Network
    end
  end
end
