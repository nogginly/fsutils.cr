module FsUtils
  class Tools
    # Codes are a closed set, so a model can branch on them. Closed does not
    # mean short — it means enumerated here rather than invented at the call
    # site.
    module ErrorCode
      OUTSIDE_SANDBOX  = "path_outside_sandbox"
      NOT_FOUND        = "path_not_found"
      INVALID_PATTERN  = "invalid_pattern"
      INVALID_ARGUMENT = "invalid_argument"
    end

    # `message` says what happened; `suggestion` says what to do instead.
    #
    # The two are separate because a model acts on an instruction far more
    # reliably than it infers one from a description. A suggestion is omitted
    # when there is honestly nothing useful to say — an invented one is worse
    # than none, since it will be followed.
    struct ErrorInfo
      include JSON::Serializable
      getter code : String
      getter message : String
      getter suggestion : String?

      def initialize(@code : String, @message : String, @suggestion : String? = nil)
      end
    end

    # What every tool result carries, whatever the tool.
    #
    # Deliberately only four fields. `path` is not among them: a search returns
    # many paths inside its results and has no single one, and a field absent
    # from one member of a set is not common to the set.
    #
    # Ivars declared here serialise before the including struct's own, so `ok`
    # leads every response — which is the first thing a model branches on.
    module Envelope
      # False means the call did not happen: `error` says why, and every other
      # field is absent. An empty result and a failure are different answers.
      getter? ok : Bool

      # The one flag worth branching on across every tool. Its *reasons* differ
      # — a sampled walk, a prefix of a file — which is why each response names
      # its own reason in its own field rather than forcing one vocabulary.
      getter truncated : Bool?

      # Prose aimed at the model, present only when something needs saying.
      # Where a reason field states a fact, this states the action.
      getter notice : String?

      getter error : ErrorInfo?
    end
  end
end
