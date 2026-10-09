# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # The ask-maestro bridge for the ask_question tool's subagent plane.
      # Flips the instance to :waiting_input, announces the question on the
      # event bus (REASON carries the full display text incl. options —
      # Notices needs no question-specific plumbing), then polls the shared
      # inbox for the maestro's send_message reply. The worker thread is the ONLY
      # inbox drainer (drain_inbox_into_history runs between steps) and it is
      # blocked inside the tool here, so the pop cannot race a drain.
      # Polling (not a cond var) follows the Supervisor#wait_for precedent:
      # kill hard-kills the thread, so perfect signaling is not required.
      module Questioner
        DEFAULT_QUESTION_TIMEOUT = 300

        # Returns the answer String, :unavailable (no bus / wrong state —
        # nobody can ever answer, so blocking would be wrong), or nil when
        # unanswered (timeout or kill).
        def ask_init0(question_text, options: [], timeout: nil)
          return :unavailable unless @event_bus

          # Drain pending steers into history FIRST (same discipline as the
          # step top): a pre-question inbox message was NOT sent to a
          # question-waiting subagent and must not pose as its answer.
          drain_inbox_into_history
          reason = Array(options).empty? ? question_text.to_s : "#{question_text} (options: #{Array(options).join(' / ')})"
          payload = { id: @id, role: @role, state: :waiting_input,
                      reason: reason, timeout: question_timeout(timeout) }
          @monitor.synchronize do
            return :unavailable unless executing?

            transition!(:waiting_input)
            @unit&.sync_state!
          end
          answer = nil
          begin
            # Emit OUTSIDE the monitor (budget-pause discipline): synchronous
            # bus dispatch finishes before the poll starts, so the answer can
            # never land before we begin waiting for it.
            Notices.emit(@event_bus, Notices::QUESTION_EVENT, payload)
            deadline = Time.now + payload[:timeout]
            until answer
              @monitor.synchronize { answer = @inbox.pop(true)&.text unless @inbox.empty? }
              break if Time.now >= deadline || !(awaiting_human? || executing?)

              sleep 0.1
            end
          ensure
            # Guarded restore (also covers a raise or Thread#kill mid-wait):
            # grant_budget! or kill may have legitimately moved the state on.
            @monitor.synchronize do
              transition!(:running) if awaiting_human?
              @unit&.sync_state!
            end
          end
          if answer.nil? && Time.now >= deadline
            # The subagent-side timeout escalation ("proceed with your best
            # judgment") is invisible to the maestro — it woke nobody. The
            # timed-out notice re-surfaces the dead-end on the next wake so a
            # late answer becomes a conscious choice, not a shot into a void
            # the asker already left (issue #97 finding 4). The human-readable
            # marker is appended by Notices.normalize AFTER its reason cap, so
            # it can never be truncated away; here the state alone carries it.
            Notices.emit(@event_bus, Notices::QUESTION_EVENT, payload.merge(state: :question_timed_out))
          end
          answer
        end

        def question_timeout(override = nil)
          return override.to_f if override&.to_f&.positive?

          (@config.respond_to?(:fetch) ? @config.fetch("subagents.question_timeout", DEFAULT_QUESTION_TIMEOUT) : DEFAULT_QUESTION_TIMEOUT) ||
            DEFAULT_QUESTION_TIMEOUT
        end
      end
    end
  end
end
