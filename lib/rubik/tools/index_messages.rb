# frozen_string_literal: true

module Rubik
  module Tools
    # Shared wording for the tools that consume the context index: one
    # prefix keeps the not-ready phrasing consistent across tools.
    module IndexMessages
      # The index exists but holds no files. Tools append their own
      # escape-hatch tail to this prefix.
      INDEX_NOT_READY_PREFIX = "Context index has no files indexed yet (still building, or the scan failed). " \
                               "Run '!context scan' to build it, or "

      # The index coeffect is absent entirely: nothing to search against.
      INDEX_UNAVAILABLE_MESSAGE = "Context index is not available. Run '!context scan' or restart the session to build it."
    end
  end
end
