# frozen_string_literal: true

require_relative "../log"

module Rubik
  module Orchestrator
    # Premature goal-completion guard (maestro lifecycle round 4; field
    # incident 2026-10-05): in goal mode a text-only conclusion or a
    # `finish` call used to end the run with success while dispatched
    # subagents were still running — "Goal Achieved" over a live pipeline.
    # GoalWait owns the implicit yield-and-wait that replaces that
    # terminal: block on the supervisor (bounded, burns no step), deliver
    # pending notices into history, and hand the turn back so the maestro
    # reacts and re-attempts completion only once nothing dispatched
    # remains. Interactive mode never reaches this object — the user
    # channel guards on Loop#goal_mode?.
    class GoalWait
      DEFAULT_TIMEOUT = 300

      def initialize(deps)
        @deps = deps
      end

      # Live dispatched work: any active unit (running, paused on error or
      # budget, or blocked on an ask_question answer) counts — none of them
      # may be abandoned by a completion. A nil supervisor (no subagent
      # system, bare test loops) means nothing is pending.
      def pending?
        active_count.positive?
      end

      def active_count
        supervisor&.active_count.to_i
      end

      # Called by the user channel INSTEAD of building the success
      # terminal. Always returns nil — the step loop continues and the
      # model re-attempts completion once the injected messages say the
      # pipeline has settled. Never returns a terminal itself: the guard
      # must not become a second completion path.
      def premature_yield!(via:)
        inbox = @deps.loop_instance.subagent_notice_inbox
        return inject_notices! unless inbox.empty?

        timeout = wait_timeout
        @deps.on_step&.call(type: :goal_wait, via: via, active: active_count, timeout: timeout,
                            step: @deps.step_count, max_steps: @deps.max_steps)
        # Notices arriving while the model was concluding sit in the inbox;
        # wait_for blocks until the whole dispatched set settles (budget-
        # and error-paused units emit their notice and are excluded here,
        # so the inbox check below re-prompts the maestro to steer them).
        supervisor&.wait_for(nil, timeout: timeout) if timeout.positive?

        return inject_notices! unless inbox.empty?
        return timeout_nudge! if pending?

        settled_nudge!
      end

      private

      def supervisor
        @supervisor ||= Rubik::Coeffects.get(@deps.runtime_manager&.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
      rescue StandardError => e
        # Absence never raises (Coeffects.get is nil-safe), so this branch
        # is real breakage and the guard goes INERT for the rest of the
        # run — warn unconditionally; the REPL completion defense
        # (agent_execution.rb) still refuses a false "Goal Achieved" in
        # that world by failing conservative.
        Rubik::Log.warn(:orchestrator, "goal wait: supervisor resolution failed (#{e.class}: #{e.message}); " \
                                       "premature-completion guard inert for this run")
        nil
      end

      def wait_timeout
        raw = @deps.safe_config("agent.goal_wait_timeout", DEFAULT_TIMEOUT)
        return raw.to_i if raw.is_a?(Numeric)
        # "0"/"300" honor the user; garbage ("5min") must not degrade to a
        # zero wait — fall back to the default bound.
        return raw.to_i if raw.to_s.match?(/\A\s*-?\d+\s*\z/)

        DEFAULT_TIMEOUT
      rescue KeyError, TypeError, NoMethodError
        DEFAULT_TIMEOUT
      end

      # Drains the inbox into history through the loop's own merge seam and
      # continues the loop — the model evaluates the notice digest on its
      # next turn, exactly like the interactive reactive wake.
      def inject_notices!
        @deps.loop_instance.drain_subagent_notices_into_history!
        nil
      end

      # Deadline hit with live units: one step is spent telling the model
      # the wait is still open. Concluding again re-arms the implicit wait,
      # so a model that has nothing to add cycles cheaply instead of
      # falsely completing.
      def timeout_nudge!
        append_user_message!(
          "<goal_wait_timeout active=\"#{active_count}\" timeout=\"#{wait_timeout}\">#{active_count} dispatched " \
          "subagent(s) are still running. The goal is NOT complete while they run. Conclude your turn again to " \
          "keep waiting, or inspect and steer them (`manage_subagents` action 'status' | 'wait' | 'kill'). " \
          "Call finish only once every dispatched subagent has settled.</goal_wait_timeout>"
        )
        nil
      end

      # Everything settled during the wait without a single notice — only
      # reachable when notice routing is absent (test doubles). The model,
      # not the guard, draws the completion conclusion.
      def settled_nudge!
        append_user_message!(
          "<goal_wait_settled>All dispatched subagents have settled with no pending notices. " \
          "Verify their outcomes and conclude the goal (finish) if the objective is met.</goal_wait_settled>"
        )
        nil
      end

      def append_user_message!(xml)
        @deps.history << { role: "user", content: xml }
      end
    end
  end
end
