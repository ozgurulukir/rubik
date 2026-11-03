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

      # Suffix for SUCCESS results served from a PARTIAL index: the model
      # must never mistake a truncated index for ground truth. Returns nil
      # for a clean scan so success output stays unchanged.
      module_function

      # Reads the completeness verdict off an index's status_summary; nil
      # for a clean scan or an object without the summary seam (test doubles).
      def note_for(idx)
        return nil unless idx.respond_to?(:status_summary)

        summary = idx.status_summary
        partial_index_note(summary[:last_scan_aborted], summary[:last_scan_error])
      end

      def partial_index_note(aborted, error)
        return nil unless aborted

        " Note: the context index is PARTIAL — the last scan aborted" \
          "#{" (#{error})" if error}. Results may be missing files; '!context scan' rebuilds it."
      end
    end
  end
end
