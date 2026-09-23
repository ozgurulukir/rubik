# frozen_string_literal: true

require_relative "../../platform"
require_relative "budget"

module Rubik
  module Orchestrator
    module Subagent
      # THE single vocabulary home for subagent notices: event names and
      # payloads enter, two channel renderings leave (user channel: REPL
      # hints allowed; model channel: tool-oriented). Pure functions, hashes
      # in, strings out — never touches the bus, shell state or Loop history
      # (the REPL subscriber routes; the Loop drain renders .history_block).
      module Notices
        module_function

        # Bus event names (single source: Supervisor, Instance, StepRunner
        # emit; the REPL subscriber listens).
        COMPLETED_EVENT = :subagent_completed
        BUDGET_EXHAUSTED_EVENT = :subagent_budget_exhausted
        COMPACTED_EVENT = :subagent_context_compacted
        AUTO_APPLY_FAILED_EVENT = :subagent_auto_apply_failed

        # Bus event name -> normalized notice kind.
        EVENTS = {
          COMPLETED_EVENT => :completed,
          BUDGET_EXHAUSTED_EVENT => :budget_exhausted,
          COMPACTED_EVENT => :context_compacted,
          AUTO_APPLY_FAILED_EVENT => :auto_apply_failed
        }.freeze

        # Normalizes a bus payload into the notice dialect; unknown -> nil.
        def normalize(event_name, payload)
          kind = EVENTS[event_name.to_sym]
          return nil unless kind

          notice = { kind: kind, id: payload[:id].to_s, role: payload[:role].to_s,
                     state: payload[:state].to_s, max_steps: payload[:max_steps] }
          # Provider error text gets a hard cap: diagnostic color, not payload.
          notice[:reason] = payload[:reason].to_s.slice(0, 120) if [:context_compacted, :auto_apply_failed].include?(kind)
          notice
        end

        # User channel: terminal wording. REPL command syntax is allowed HERE
        # ONLY. The completed event fires for every terminal exit.
        def user_line(notice)
          if notice[:kind] == :context_compacted
            detail = notice[:reason].to_s.empty? ? "" : " (#{notice[:reason]})"
            "🧹 [Subagent Compacted] [#{notice[:id]}] '#{notice[:role]}' recovered from a provider " \
              "context-limit error by compacting its own history; work continues#{detail}."
          elsif notice[:kind] == :auto_apply_failed
            "⚠️ [Subagent Auto-Apply] [#{notice[:id]}] '#{notice[:role]}' could not auto-apply its " \
              "buffer (#{notice[:reason]}). Changes remain unapplied."
          elsif notice[:kind] == :budget_exhausted
            "⚠️ [Subagent Paused] [#{notice[:id]}] '#{notice[:role]}' reached step budget " \
              "(#{notice[:max_steps]} steps). Run '!subagents extend #{notice[:id]}' to resume."
          elsif notice[:state] == "budget_exhausted"
            "🛑 [Subagent Budget Exhausted] [#{notice[:id]}] '#{notice[:role]}' - BUDGET_EXHAUSTED (task incomplete)"
          elsif notice[:state] == "failed"
            "❌ [Subagent Failed] [#{notice[:id]}] '#{notice[:role]}' - FAILED. " \
              "Call manage_subagents(action: 'status', conversation_id: '#{notice[:id]}') for the error."
          elsif notice[:state] == "completed"
            "⚡ [Subagent Completed] [#{notice[:id]}] '#{notice[:role]}' - COMPLETED"
          else
            "🏁 [Subagent Finished] [#{notice[:id]}] '#{notice[:role]}' - #{notice[:state].upcase}"
          end
        end

        # Model channel: tool-oriented XML element. Results are deliberately
        # NOT carried — the model retrieves them via manage_subagents.
        def model_element(notice)
          attrs = { kind: notice[:kind], id: notice[:id], role: notice[:role], state: notice[:state] }
          attrs[:max_steps] = notice[:max_steps] if notice[:kind] == :budget_exhausted
          attrs[:reason] = notice[:reason] if [:context_compacted, :auto_apply_failed].include?(notice[:kind]) && !notice[:reason].to_s.empty?
          attrs[:guidance] = guidance_for(notice)
          rendered = attrs.map { |k, v| %(#{k}="#{Rubik::Platform.xml_escape(v)}") }.join(" ")
          "<notification #{rendered} />"
        end

        # <subagent_notifications> block the Loop drain merges into history.
        def history_block(notices)
          elements = notices.map { |n| "  #{model_element(n)}" }.join("\n")
          "<subagent_notifications>\n#{elements}\n</subagent_notifications>"
        end

        def guidance_for(notice)
          if notice[:kind] == :context_compacted
            "No action needed: the subagent recovered automatically; its history was compacted, " \
              "so early details may be summarized."
          elsif notice[:kind] == :auto_apply_failed
            "Auto-apply failed; changes remain unapplied. Apply via the apply_buffer tool."
          elsif notice[:kind] == :budget_exhausted
            "Resume via #{extend_budget_hint(notice[:id])} or kill it with action: 'kill'."
          elsif notice[:state] == "budget_exhausted"
            budget_exhausted_line(notice[:max_steps])
          else
            "Retrieve the full result with #{wait_hint(notice[:id])}."
          end
        end

        # -- Shared budget phrase family -----------------------------------
        # Rendered by status/wait guidance, instance results and notice
        # guidance — exact spellings so they cannot drift; counts included.

        # Paused verdict for the model channel (embeds the resume hint).
        def budget_paused_line(id, max_steps)
          "Subagent reached step budget (#{max_steps} steps) and paused. Call #{extend_budget_hint(id)} to resume."
        end

        # Halted verdict; a nil max_steps drops the step count.
        def budget_exhausted_line(max_steps = nil)
          count = max_steps ? " (#{max_steps} steps)" : ""
          "Subagent reached step budget#{count} and halted: task was NOT completed. Inspect transcript or spawn a new subagent."
        end

        # -- Tool-invocation hint family ----------------------------------
        # manage_subagents snippets taught to the model: single source,
        # single-quote kwargs dialect, byte-identical at every site (tool
        # output, guidance, prompt layer). Purity: platform + budget leaf.

        # Seconds the wait protocol advertises; the manage tool reads it too.
        DEFAULT_WAIT_TIMEOUT = 30

        # THE one implementation point for id-list quote style (no Array#inspect).
        def render_ids(ids)
          "[#{Array(ids).map { |id| "'#{id}'" }.join(', ')}]"
        end

        def wait_hint(ids, timeout: DEFAULT_WAIT_TIMEOUT)
          "manage_subagents(action: 'wait', conversation_ids: #{render_ids(ids)}, timeout: #{timeout})"
        end

        def wait_any_hint(timeout: DEFAULT_WAIT_TIMEOUT)
          "manage_subagents(action: 'wait', timeout: #{timeout})"
        end

        # Placeholder form for prompt-layer teaching ([...] = id slot).
        def wait_hint_template
          "manage_subagents(action: 'wait', conversation_ids: [...], timeout: #{DEFAULT_WAIT_TIMEOUT})"
        end

        # Resumes a budget-paused subagent (budget_paused_line renders it).
        def extend_budget_hint(id, steps: Budget::DEFAULT_GRANT_STEPS)
          "manage_subagents(action: 'extend_budget', conversation_id: '#{id}', steps: #{steps})"
        end
      end
    end
  end
end
