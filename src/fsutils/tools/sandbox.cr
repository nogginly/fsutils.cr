module FsUtils
  class Tools
    # Confines every path an agent supplies to a single root.
    #
    # The helpers take a caller wherever they are pointed, which is right for
    # trusted local code. This layer assumes its caller is a language model
    # that may have read `../../.ssh/id_rsa` somewhere and thought it looked
    # interesting.
    #
    # The rule is **resolve, then compare** — never validate the string before
    # resolving it, because `..` and symlinks both launder a path past a naive
    # prefix check.
    #
    # ```
    # sandbox = FsUtils::Tools::Sandbox.new("/srv/project")
    # sandbox.resolve("src/main.cr") # => "/srv/project/src/main.cr"
    # sandbox.resolve("../etc")      # raises Escape
    # ```
    struct Sandbox
      # Raised when a requested path resolves outside the root. Surfaces to an
      # agent as the `path_outside_sandbox` error code.
      class Escape < FsUtils::Error
      end

      # The canonical root. Absolute, symlinks resolved, no trailing separator.
      getter root : String

      def initialize(root : String)
        expanded = ::File.expand_path(root)

        @root = begin
          ::File.realpath(expanded)
        rescue ex : ::File::Error | IO::Error
          raise FsUtils::Error.new("sandbox root #{root.inspect} is unusable: #{ex.message}")
        end

        unless ::File.directory?(@root)
          raise FsUtils::Error.new("sandbox root #{root.inspect} is not a directory")
        end
      end

      # Resolves a requested path and confirms it lands inside the root.
      #
      # The path need not exist: a lookup of a missing file *inside* the
      # sandbox should fail later as an honest "not found", not here as a
      # resolution error. Raises `Escape` if it lands outside.
      def resolve(requested : String) : String
        joined = if requested.empty?
                   @root
                 elsif requested.starts_with?(::File::SEPARATOR)
                   # Already absolute; taken at face value and checked below.
                   requested
                 else
                   ::File.join(@root, requested)
                 end

        candidate = canonical(::File.expand_path(joined))
        raise Escape.new("path #{requested.inspect} resolves outside the sandbox") unless inside?(candidate)
        candidate
      end

      # Resolves several paths, defaulting to the root when none were given.
      def resolve_all(requested : Array(String)) : Array(String)
        return [@root] if requested.empty?
        requested.map { |path| resolve(path) }
      end

      # True when `path` is the root or lies beneath it.
      #
      # The separator check is the whole point: a bare `starts_with?` lets
      # `/srv/project-secrets` pass for root `/srv/project`.
      def inside?(path : String) : Bool
        return true if path == @root
        path.starts_with?(@root + ::File::SEPARATOR)
      end

      # Strips the root, so an agent never learns the host's absolute layout.
      # A small security win and a meaningful saving in tokens.
      def relative(path : String) : String
        return "." if path == @root
        return path unless inside?(path)
        path[(@root.size + 1)..]
      end

      # Resolves symlinks and `..` as far as the filesystem allows, then
      # re-attaches whatever tail does not exist yet.
      #
      # Resolving only the existing prefix is deliberate. `realpath` on a
      # missing path fails outright, and refusing to answer would turn every
      # "does this file exist" question into an error.
      private def canonical(path : String) : String
        tail = [] of String
        current = path

        loop do
          if exists?(current)
            real = ::File.realpath(current)
            return real if tail.empty?
            return ::File.join(real, tail.reverse!.join(::File::SEPARATOR))
          end

          parent = ::File.dirname(current)
          break if parent == current # reached the filesystem root

          tail << ::File.basename(current)
          current = parent
        end

        path
      rescue ::File::Error | IO::Error
        # A resolution failure is not a licence to skip the containment check;
        # the un-resolved path is checked instead, and will almost certainly
        # fail it.
        path
      end

      # Deliberately does not follow symlinks: a dangling link exists as an
      # entry even though its target does not, and treating it as missing
      # would resolve the wrong thing.
      private def exists?(path : String) : Bool
        ::File.info(path, follow_symlinks: false)
        true
      rescue
        false
      end
    end
  end
end
