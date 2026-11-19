# frozen_string_literal: true

require "securerandom"

require_relative "../../storage/layout"

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
      # The answer wait is a ConditionVariable guarded by the same @monitor
      # that guards @inbox (mirroring Supervisor's @wait_cond idiom); the
      # emitter (Instance#post_message) broadcasts OUTSIDE the critical
      # section. Kill hard-kills the thread, so no signal is needed there.
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
          question_id = "q-#{SecureRandom.hex(4)}"
          reason = Array(options).empty? ? question_text.to_s : "#{question_text} (options: #{Array(options).join(' / ')})"
          payload = { id: @id, role: @role, state: :waiting_input, question_id: question_id,
                      reason: reason, timeout: question_timeout(timeout) }
          @monitor.synchronize do
            return :unavailable unless executing?

            transition!(:waiting_input)
            # Open the pairing slot (issue #595-4 follow-up): only a reply
            # that echoes THIS id poses as the answer, so a steering message
            # pushed mid-window can never be consumed as the answer.
            @pending_question_id = question_id
            @unit&.sync_state!
          end
          answer = nil
          begin
            # Emit OUTSIDE the monitor (budget-pause discipline): synchronous
            # bus dispatch finishes before the wait starts, so the answer can
            # never land before we begin waiting for it.
            Notices.emit(@event_bus, Notices::QUESTION_EVENT, payload)
            deadline = Time.now + payload[:timeout]
            @monitor.synchronize { @answer_cond ||= @monitor.new_cond }
            unclaimed = []
            until answer
              @monitor.synchronize do
                # Only messages whose in_reply_to matches the pending
                # question id pose as the answer (issue #595-4 follow-up):
                # the push-time answer tag now requires the pairing, so a
                # steering message arriving DURING the :waiting_input window
                # — pushed without a matching in_reply_to — is stashed and
                # re-queued below so the next step-top drain delivers it as
                # a normal message row instead.
                until answer || @inbox.empty?
                  begin
                    msg = @inbox.pop(true)
                  rescue ThreadError
                    break
                  end
                  if msg&.answer && msg.in_reply_to == question_id
                    answer = msg.text
                  else
                    unclaimed << msg
                  end
                end
                # Sleep on the cond var INSIDE the monitor (wait atomically
                # releases it), bounded by the deadline. The emitter's
                # broadcast outside the critical section cannot be lost:
                # a push can only interleave while we are in wait.
                @answer_cond.wait([deadline - Time.now, 0].max) unless answer
              end
              break if Time.now >= deadline || !(awaiting_human? || executing?)
            end
          ensure
            # Re-queue unclaimed messages in arrival order so
            # drain_inbox_into_history (next step top) delivers them — the
            # worker is still the only drainer here (it is this thread,
            # blocked inside the tool). A failed re-queue must be observable,
            # never silently swallowed (AGENTS.md §5).
            begin
              unclaimed&.each { |msg| @inbox.push(msg) }
            rescue StandardError => e
              Rubik::Log.warn(:subagent, "[Questioner] re-queue of #{unclaimed.to_a.size} unclaimed " \
                                         "inbox message(s) failed: #{e.class}: #{e.message}")
            end
            # Close the pairing slot BEFORE the guarded restore: after this
            # point no push can claim the (now dead) question id.
            @monitor.synchronize do
              @pending_question_id = nil
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

          Rubik::Storage::Layout.config_get(@config, "subagents.question_timeout", DEFAULT_QUESTION_TIMEOUT) ||
            DEFAULT_QUESTION_TIMEOUT
        end

        # Emitter-side signal (mirror of Supervisor#notify_wait!): the
        # broadcast happens outside the caller's critical section, and a
        # nil cond just means nobody is waiting on an answer.
        def notify_answer!
          @monitor.synchronize { @answer_cond&.broadcast }
        end
      end
    end
  end
end
