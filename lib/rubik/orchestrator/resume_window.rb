# frozen_string_literal: true

require_relative "../prompt"
require_relative "shell_deps"

module Rubik
  module Orchestrator
    # Loop-side resume window (issue #475, the Loop mirror of GoalSession's
    # resume drive from #459). One collaborator owns the three concerns the
    # resume path used to scatter across the run loop:
    #
    # 1. ctx.extend lifecycle — the §6 discipline: an in-process resume
    #    disposes the (already run()-disposed) old per-run sub-context
    #    BEFORE extending a fresh one, so repeated suspend/resume cycles do
    #    not leak dead children; the ensure-side close disposes exactly once.
    # 2. Cross-process history prefix construction — the Σ-only window
    #    [system prompt] → [task] → [Σ row], shaped so the first resumed
    #    step's ledger refresh repositions (not duplicates) the Σ row.
    # 3. goal_resumed marker stamping — downtime formatting and the
    #    300-character reason discipline, testable without running a turn.
    #
    # System-prompt rendering and state fingerprinting stay on Loop (shared
    # with run()'s prompt view, candidate 2 Phase 2); their VALUES are passed
    # in, so this collaborator renders nothing itself.
    class ResumeWindow
      def initialize(deps)
        @deps = ShellDeps.wrap(deps)
      end

      # ── ctx.extend lifecycle (§6) ─────────────────────────────────────
      # In-process resume: the suspended run's sub-context is dead already
      # (run()'s ensure disposed it) — dispose again defensively, then
      # extend a fresh child for the resumed window.
      def reopen_context!
        @deps.reopen_run_context!
      end

      # Cross-process resume: a fresh Loop has no prior sub-context — just
      # extend. Disposing first would be a no-op on nil, but the distinct
      # entry point keeps the two resume paths' invariants explicit.
      def open_context!
        @deps.open_run_context!
      end

      # ensure-side dispose of the window's sub-context.
      def close_context!
        @deps.dispose_run_context!
      end

      # ── cross-process history prefix ──────────────────────────────────
      # Builds [system-prompt row] → [task row] → [Σ row] on the loop's
      # history. The system prompt CONTENT is supplied by the caller (Loop
      # renders via its shared prompt view); this method owns the ordering
      # and the Σ-row placement contract.
      def build_cross_process_prefix!(goal_text:, ledger:, system_prompt:)
        history << { role: "system", content: system_prompt }
        history << { role: "user", content: Rubik::Prompt::ContextBuilder.format_user_task(goal_text) }
        history << { role: "user", content: ledger.to_xml }
      end

      # ── goal_resumed marker ───────────────────────────────────────────
      # Signature row (last link of the cross-process window): role "user"
      # (EmergencyCompactor hard tier does not touch it), single-tag quoting
      # discipline (ledger_row?/drift_row? mold). downtime is human-readable,
      # "unknown" when unknowable. reason obeys the same 300-character
      # discipline as the Σ stamp — 5xx bodies must not bloat history.
      def stamp_resume_marker!(reason:, suspended_at:, attempt:)
        esc = Rubik::Platform.method(:xml_escape)
        history << { role: "user", content: "<goal_resumed downtime=\"#{esc.call(format_downtime(suspended_at))}\" " \
                                            "reason=\"#{esc.call(reason.to_s.slice(0, 300))}\" attempt=\"#{attempt.to_i}\" " \
                                            "steps_done=\"#{@deps.step_count}\" />" }
      end

      private

      def history
        @deps.history
      end

      # seconds → "45s" / "4m 12s" / "1h 03m"; honest "unknown" when the
      # suspend time is unavailable (corrupt cross-process meta). Negative
      # drift (clock skew) clamps to 0.
      def format_downtime(suspended_at)
        return "unknown" unless suspended_at.respond_to?(:to_i) && suspended_at.to_i.positive?

        secs = [(Time.now - suspended_at).to_i, 0].max
        mm, ss = secs.divmod(60)
        hh, mm = mm.divmod(60)
        return "#{hh}h #{mm.to_s.rjust(2, '0')}m" if hh.positive?
        return "#{mm}m #{ss.to_s.rjust(2, '0')}s" if mm.positive?

        "#{ss}s"
      end
    end
  end
end
