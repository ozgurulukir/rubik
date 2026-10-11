# frozen_string_literal: true

require_relative "../../platform"
require_relative "budget"

module Rubik
  module Orchestrator
    module Subagent
      # THE single vocabulary home for subagent notices: event names and
      # payloads enter, two channel renderings leave (user channel: REPL
      # hints allowed; model channel: tool-oriented).
      module Notices
        module_function

        # Bus event names
        COMPLETED_EVENT = :subagent_completed
        BUDGET_EXHAUSTED_EVENT = :subagent_budget_exhausted
        COMPACTED_EVENT = :subagent_context_compacted
        AUTO_APPLY_FAILED_EVENT = :subagent_auto_apply_failed
        ERROR_PAUSED_EVENT = :subagent_error_paused
        QUESTION_EVENT = :subagent_question
        MESSAGE_EVENT = :subagent_message_to_parent

        # Bus event name -> normalized notice kind.
        EVENTS = {
          COMPLETED_EVENT => :completed,
          BUDGET_EXHAUSTED_EVENT => :budget_exhausted,
          COMPACTED_EVENT => :context_compacted,
          AUTO_APPLY_FAILED_EVENT => :auto_apply_failed,
          ERROR_PAUSED_EVENT => :error_paused,
          QUESTION_EVENT => :question
        }.freeze

        # Sessizlik (§4.3): bu roller notice ÜRETMEZ, yalnız dmesg'e düşer (Distiller + Context Pruner).
        SILENT_ROLES = ["Vakanüvis Distiller", "Context Pruner"].freeze

        # Dmesg-plane emission metadata (bug-llm-timeout-observability): every
        # subagent-plane event lands in the ring under subsystem :subagent with
        # an operational-weight severity, so dmesg(level:/subsystem:) surfaces
        # a stalled subagent. MESSAGE_EVENT routes here too (a :message notice
        # via handle_parent_message, not normalize).
        SUBSYSTEM = :subagent

        SEVERITIES = {
          COMPLETED_EVENT => :info,
          BUDGET_EXHAUSTED_EVENT => :warn,
          COMPACTED_EVENT => :info,
          AUTO_APPLY_FAILED_EVENT => :warn,
          ERROR_PAUSED_EVENT => :err,
          QUESTION_EVENT => :notice,
          MESSAGE_EVENT => :info
        }.freeze

        # The one emission door: severity and subsystem are decided HERE,
        # never re-derived at call sites. Nil bus = the old `&.emit` skip;
        # a bus lacking #emit still raises loud; a legacy 2-arity emit gets
        # a plain 2-arg call (severity metadata best-effort, delivery
        # load-bearing). `fallback:` flips a raise into a stderr warn (the
        # AutoApply.report_failure pattern) for load-bearing event sites.
        def emit(bus, event_name, payload, fallback: nil)
          return if bus.nil?

          emit_it = lambda {
            m = bus.method(:emit)
            kw = { subsystem: SUBSYSTEM, level: SEVERITIES.fetch(event_name, :info) }
            if m.parameters.any? { |p| [:key, :keyrest].include?(p.first) }
              m.call(event_name, payload, **kw)
            else
              m.call(event_name, payload)
            end
          }
          emit_it.call
        rescue StandardError => e
          raise if fallback.nil?

          warn("#{fallback} (#{e.class}: #{e.message})")
        end

        def normalize(event_name, payload)
          return nil if SILENT_ROLES.include?(payload[:role].to_s)

          kind = EVENTS[event_name.to_sym]
          return nil unless kind

          notice = { kind: kind, id: payload[:id].to_s, role: payload[:role].to_s,
                     state: payload[:state].to_s, max_steps: payload[:max_steps] }
          raw_err = payload[:error] || payload[:reason]
          # Q-timeout marker rides AFTER the cap (#97): truncation can never eat it.
          if kind == :question && notice[:state] == "question_timed_out"
            notice[:reason] = "#{raw_err.to_s.slice(0, 230)} [timed out unanswered after #{payload[:timeout]}s — proceeding on its own judgment]"
          elsif [:context_compacted, :auto_apply_failed, :error_paused, :question].include?(kind)
            notice[:reason] = raw_err.to_s.slice(0, kind == :question ? 300 : 120)
          end
          notice[:timeout] = payload[:timeout] if kind == :question
          # B11: grant/step markers make repeated pauses distinguishable.
          if kind == :budget_exhausted
            notice[:grants] = payload[:grants].to_i if payload[:grants].to_i.positive?
            notice[:step] = payload[:step].to_i if payload[:step].to_i.positive?
          end
          notice
        end

        def user_line(notice)
          case notice[:kind]
          when :context_compacted
            detail = notice[:reason].to_s.empty? ? "" : " (#{notice[:reason]})"
            "🧹 [Subagent Compacted] [#{notice[:id]}] '#{notice[:role]}' recovered from a provider context-limit error by compacting its own history; work continues#{detail}."
          when :auto_apply_failed
            "⚠️ [Subagent Auto-Apply] [#{notice[:id]}] '#{notice[:role]}' could not auto-apply its buffer (#{notice[:reason]}). Changes remain unapplied."
          when :budget_exhausted
            grants = notice[:grants].to_i
            step = notice[:step]
            cyc = " again (after #{grants} grant(s) consumed#{", at step #{step}" if step})" if grants.positive?
            "⚠️ [Subagent Paused] [#{notice[:id]}] '#{notice[:role]}' reached step budget#{cyc} " \
              "(#{notice[:max_steps]} steps). Run '!subagents extend #{notice[:id]}' to resume."
          when :error_paused
            "⚠️ [Subagent Paused] [#{notice[:id]}] '#{notice[:role]}' paused due to provider/network error (#{notice[:reason]}). Run '!subagents resume #{notice[:id]}' to retry."
          when :message
            "💬 [Message from #{notice[:id]}] #{notice[:reason]}"
          when :question
            badge = notice[:state] == "question_timed_out" ? "⌛ [Question timed out] [#{notice[:id]}]" : "❓ [Question from #{notice[:id]}]"
            "#{badge} '#{notice[:role]}': #{notice[:reason]}"
          when :task
            badge = notice[:state] == "completed" ? "⚡ [Task Done]" : "❌ [Task Failed]"
            "#{badge} [#{notice[:id]}] - #{notice[:state].to_s.upcase}"
          else
            case notice[:state]
            when "budget_exhausted"
              "🛑 [Subagent Budget Exhausted] [#{notice[:id]}] '#{notice[:role]}' - BUDGET_EXHAUSTED (task incomplete)"
            when "failed"
              "❌ [Subagent Failed] [#{notice[:id]}] '#{notice[:role]}' - FAILED. Call manage_subagents(action: 'status', conversation_id: '#{notice[:id]}') for the error."
            when "completed"
              "⚡ [Subagent Completed] [#{notice[:id]}] '#{notice[:role]}' - COMPLETED"
            else
              "🏁 [Subagent Finished] [#{notice[:id]}] '#{notice[:role]}' - #{notice[:state].to_s.upcase}"
            end
          end
        end

        def model_element(notice)
          attrs = { kind: notice[:kind], id: notice[:id], role: notice[:role], state: notice[:state] }
          attrs[:max_steps] = notice[:max_steps] if notice[:kind] == :budget_exhausted
          reason_kinds = [:context_compacted, :auto_apply_failed, :error_paused, :message, :task, :question]
          attrs[:reason] = notice[:reason] if reason_kinds.include?(notice[:kind]) && !notice[:reason].to_s.empty?
          attrs[:timeout] = notice[:timeout] if notice[:kind] == :question && notice[:timeout]
          attrs[:guidance] = guidance_for(notice)
          rendered = attrs.map { |k, v| %(#{k}="#{Rubik::Platform.xml_escape(v)}") }.join(" ")
          "<notification #{rendered} />"
        end

        def history_block(notices)
          elements = notices.map { |n| "  #{model_element(n)}" }.join("\n")
          "<subagent_notifications>\n#{elements}\n</subagent_notifications>"
        end

        # Event-channel guidance (notice-kind keyed); instance-state narration lives in Narration.
        def guidance_for(notice)
          case notice[:kind]
          when :task
            "Inspect task output via manage_task(action: 'logs', task_id: '#{notice[:id]}')."
          when :context_compacted
            "No action needed: the subagent recovered automatically; its history was compacted, so early details may be summarized."
          when :auto_apply_failed
            "Auto-apply failed; changes remain unapplied. Apply via the apply_buffer tool."
          when :budget_exhausted
            "Resume via #{extend_budget_hint(notice[:id])} or kill it with action: 'kill'."
          when :error_paused
            "Subagent paused on network error. Resume via #{resume_hint(notice[:id])} or kill with action: 'kill'."
          when :message
            "Message from subagent. Respond or grant steps via send_message(recipient: '#{notice[:id]}', message: '...')."
          when :question
            answered = "No answer is needed anymore: it timed out and the subagent proceeded on its own judgment. " \
                       "A late send_message(recipient: '#{notice[:id]}') lands as a regular message."
            blocking = "Answer NOW via send_message(recipient: '#{notice[:id]}', message: '<your answer>') — " \
                       "the subagent is blocked waiting (#{notice[:timeout] || 300}s timeout)."
            notice[:state] == "question_timed_out" ? answered : blocking
          else
            if notice[:state] == "budget_exhausted"
              budget_exhausted_line(notice[:max_steps])
            else
              "Retrieve the full result with #{wait_hint(notice[:id])}."
            end
          end
        end

        def budget_paused_line(id, max_steps) = "Subagent reached step budget (#{max_steps} steps) and paused. Call #{extend_budget_hint(id)} to resume."

        def budget_exhausted_line(max_steps = nil)
          count = max_steps ? " (#{max_steps} steps)" : ""
          "Subagent reached step budget#{count} and halted: task was NOT completed. Inspect transcript or spawn a new subagent."
        end

        DEFAULT_WAIT_TIMEOUT = 30

        def render_ids(ids) = "[#{Array(ids).map { |id| "'#{id}'" }.join(', ')}]"

        def wait_hint(ids, timeout: DEFAULT_WAIT_TIMEOUT) = "manage_subagents(action: 'wait', conversation_ids: #{render_ids(ids)}, timeout: #{timeout})"

        def wait_any_hint(timeout: DEFAULT_WAIT_TIMEOUT) = "manage_subagents(action: 'wait', timeout: #{timeout})"

        def wait_hint_template = "manage_subagents(action: 'wait', conversation_ids: [...], timeout: #{DEFAULT_WAIT_TIMEOUT})"

        def extend_budget_hint(id, steps: Budget::DEFAULT_GRANT_STEPS) = "manage_subagents(action: 'extend_budget', conversation_id: '#{id}', steps: #{steps})"

        def resume_hint(id) = "manage_subagents(action: 'resume', conversation_id: '#{id}')"
      end
    end
  end
end
