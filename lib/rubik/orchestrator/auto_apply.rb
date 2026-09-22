# frozen_string_literal: true

require_relative "subagent/notices"

module Rubik
  module Orchestrator
    # Deep module (2026-09-22 review card 2): the ONE home for the buffer
    # auto-apply policy. Eight call sites carried private spellings of the
    # same decision (StepExecutor x3, subagent StepRunner x2, Supervisor
    # completion, REPL !test/!sh) and drifted: the supervisor ignored
    # buffer.auto_apply, subagent finish ignored on_finish, both subagent
    # sites swallowed apply failures (tests could silently run on stale
    # disk), the subagent steps skipped the AST sync, and the copy
    # diverged ("file(s)" vs "modified file(s)").
    #
    #   owns   : the trigger vocabulary and decision table (mode x subagent
    #            flag x tool class), the canonical apply+sync effect, the
    #            failure-notice channel, config keys/defaults, and the REPL
    #            copy vocabulary
    #   leaves : the transport at each site (on_step event, event bus, IO),
    #            which buffer instance is applied, the branch-workspace
    #            fact, and branch merge semantics (Supervisor)
    #
    # Subagent state never enters this module (stateless-over-owner,
    # ARCHITECTURE.md §2): config and trigger symbols in, booleans and
    # strings out.
    module AutoApply
      MODE_KEY = "buffer.auto_apply"           # config/defaults.rb: "manual"
      FLAG_KEY = "subagents.auto_apply_buffer" # config/defaults.rb: true

      # Defensive defaults for config-less hosts (tests, embedded). The
      # flag default deliberately diverges from defaults.rb's true: a nil
      # config reads as OFF so a config-less Supervisor never writes disk
      # (the merge-without-apply pin, test_subagent_orchestration.rb).
      # Pinned by name in test_auto_apply_policy.rb — do not "unify".
      DEFAULT_MODE = "manual"
      DEFAULT_FLAG = false

      TEST_CLASS_TOOLS = ["run_command", "run_tests", "test", "lint"].freeze

      # Trigger -> modes that fire it. on_test fires at finish on purpose:
      # the mode ladder ends every turn flushed (historical StepExecutor
      # semantics, preserved by the 2026-09-22 reconciliation). completion
      # mirrors finish for the supervisor's post-merge moment.
      TRIGGER_MODES = {
        pre_execution: ["on_test", "always"],
        finish: ["on_finish", "on_test", "always"],
        completion: ["on_finish", "on_test", "always"],
        post_tool: ["always"]
      }.freeze

      module_function

      # THE decision. subagent: true composes the subagents flag: flag on
      # enables every trigger; otherwise the mode decides per trigger.
      # tool classifies :pre_execution (nil = the caller already
      # established the test-class context, e.g. REPL !test/!sh).
      def apply?(config, trigger:, subagent: false, tool: nil)
        return false if trigger == :pre_execution && !tool.nil? && !test_class_tool?(tool)

        effective_mode = subagent && subagent_flag_on?(config) ? "always" : mode(config)
        fires?(effective_mode, trigger)
      end

      # Pure predicate on a resolved mode string — the StepExecutor
      # injection seam (its tests pass explicit modes positionally).
      def fires?(mode, trigger)
        TRIGGER_MODES.fetch(trigger).include?(mode.to_s.downcase)
      end

      # Canonical effect: apply the dirty buffer, then sync context/AST
      # unless nothing was applied. Errors PROPAGATE (the main path
      # contract); subagent callers rescue-and-report via report_failure.
      def apply_and_sync(buffer_manager, shell)
        return [] unless buffer_manager&.dirty?

        applied = buffer_manager.apply!
        shell&.sync_context_and_ast(applied) unless applied.empty?
        applied
      end

      # Report-don't-swallow channel for the subagent paths. The trigger
      # folds into reason so Notices' 120-char cap branch covers both
      # kinds. Call from a worker thread BETWEEN monitor sections — never
      # under a lock (same discipline as emergency_compact_and_notify!).
      def report_failure(event_bus, id:, role:, state:, trigger:, error:)
        if event_bus.respond_to?(:emit)
          event_bus.emit(Subagent::Notices::AUTO_APPLY_FAILED_EVENT,
                         { id: id, role: role, state: state.to_s,
                           reason: "#{trigger}: #{error.class}: #{error.message}" })
        else
          warn("[AutoApply] subagent '#{id}' auto-apply (#{trigger}) failed: #{error.class}: #{error.message}")
        end
      end

      # -- copy vocabulary (the one home for auto-apply words) ------------

      def applied_line(count, phase)
        "[Rubik::Buffer] Auto-applied #{count} modified file(s) before #{phase}."
      end

      def unapplied_warning(subject)
        "⚠️ [Rubik::Buffer] Notice: Unapplied buffer changes exist. #{subject} run against files on disk."
      end

      # -- one defensive spelling each (replaced eight) -------------------

      def mode(config)
        config.respond_to?(:fetch) ? config.fetch(MODE_KEY, DEFAULT_MODE).to_s.downcase : DEFAULT_MODE
      end

      def subagent_flag_on?(config)
        config.respond_to?(:fetch) ? config.fetch(FLAG_KEY, DEFAULT_FLAG) == true : DEFAULT_FLAG
      end

      def test_class_tool?(canonical_name)
        TEST_CLASS_TOOLS.include?(canonical_name.to_s)
      end
    end
  end
end
