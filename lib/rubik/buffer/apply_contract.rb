# frozen_string_literal: true

module Rubik
  module Buffer
    # The one home for the apply CONTRACT vocabulary (issue #146):
    #  - who may apply the buffer: the model's apply_buffer tool is gated by
    #    buffer.model_can_apply (the operator !apply flow never is);
    #  - what a mid-run failure reports: the buffer is per-file atomic, NOT
    #    a multi-file transaction, so the report names what DID reach disk,
    #    what failed, what stays dirty for a retry, and skipped conflicts.
    # Both planes (ApplyBufferTool, the !apply REPL command) render through
    # here so the truth cannot drift between model and operator output.
    module ApplyContract
      module_function

      # Authority resolution: the shell's live config wins when present; a
      # tool rebuilt without a shell (ScopedRegistry branch workspaces) falls
      # back to the buffer manager's own config. Missing config keeps the
      # documented default (true).
      def model_can_apply?(shell_config:, manager_config:)
        cfg = shell_config || manager_config
        return true if cfg.nil? || !cfg.respond_to?(:fetch)

        cfg.fetch("buffer.model_can_apply", true) != false
      end

      # Partial-apply report lines. `sync` (when given) receives the applied
      # paths and performs the context/AST sync; a raising sync is annotated,
      # never allowed to swallow the report.
      def failure_lines(failure, sync: nil)
        lines = ["Apply stopped before completing; the buffer is not a multi-file transaction:"]
        lines << if failure.applied.empty?
                   "  • Nothing was written to disk."
                 else
                   "  • Already written to disk (do not re-apply): #{failure.applied.join(', ')}"
                 end
        cause = failure.cause
        lines << "  • Failed: #{failure.failed}#{cause ? " (#{cause.class}: #{cause.message})" : " (#{failure.kind})"}"
        lines << "  • Still dirty — a retry writes only these: #{failure.pending.join(', ')}" unless failure.pending.empty?
        lines << "  • Skipped conflicts (disk changed externally): #{failure.conflicts.join(', ')}" unless failure.conflicts.empty?
        if failure.respond_to?(:skipped) && !failure.skipped.empty?
          skipped_desc = failure.skipped.map do |s|
            s.is_a?(Hash) ? "#{s[:path]} (#{s[:reason]})" : s.to_s
          end.join(", ")
          lines << "  • Skipped invalid paths (anti-injection/garbage): #{skipped_desc}"
        end
        if sync
          annotation = sync_annotation(failure, sync)
          lines << annotation if annotation
        end
        lines
      end

      # "Buffer is clean" alone reads as "nothing happened" when an earlier
      # apply (the tool or the auto-apply policy) already flushed the edits
      # to disk. Surface the last successful apply so the model can verify
      # against reality instead of re-editing or force-applying (issue #97
      # finding 6). When the mode cannot be read, the origin stays
      # deliberately two-sided rather than inventing a specific cause.
      def clean_buffer_message(last_applied, mode)
        paths = last_applied.is_a?(Hash) ? Array(last_applied[:paths]) : []
        return "No unapplied buffer changes to write (buffer is clean)." if paths.empty?

        origin = if !mode.nil? && !mode.to_s.strip.empty? && mode.to_s.downcase != "manual"
                   "the auto-apply policy (buffer.auto_apply: #{mode})"
                 else
                   "an earlier apply_buffer call or the auto-apply policy"
                 end
        "No unapplied buffer changes to write (buffer is clean): #{paths.size} file(s) were already written to disk " \
          "at #{last_applied[:at].utc.iso8601} by #{origin}: #{paths.join(', ')}."
      end

      def sync_annotation(failure, sync)
        return nil if failure.applied.empty?

        sync.call(failure.applied)
        nil
      rescue StandardError => e
        "  • context/AST sync failed for the already-written files: #{e.class}: #{e.message}"
      end
      private_class_method :sync_annotation
    end
  end
end
