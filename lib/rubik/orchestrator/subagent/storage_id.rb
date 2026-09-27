# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Mints process-unique transcript storage ids (Plan 110, closes #48).
      #
      # Display ids restart at "subagent-1" in every process, so bare display
      # ids collide across sessions sharing a workspace: transcript paths
      # derived from them let one session's save clobber another's, or serve
      # a dead run's file as live evidence (2026-09-27 phantom-subagent
      # incident). A storage id suffixes the display id with three factors:
      #   * pid — two live processes can never mint the same id;
      #   * epoch seconds — same-process re-runs (test suites) differ;
      #   * rand4 — same-second re-mints stay distinct.
      # Unlike ToolCallId — whose doc scopes it to tool-call id spellings and
      # whose bounded session histories make rand-only viable — a transcript
      # filesystem accumulates forever, so uniqueness needs pid + time.
      module StorageId
        def self.mint(display_id)
          "#{display_id}-#{Process.pid}-#{Time.now.to_i}-#{rand(1000..9999)}"
        end
      end
    end
  end
end
