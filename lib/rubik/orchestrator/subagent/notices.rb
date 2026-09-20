# frozen_string_literal: true

require_relative "../../platform"

module Rubik
  module Orchestrator
    module Subagent
      # THE single vocabulary home for subagent notices (Candidates 02/03):
      # bus event names and payloads enter; two channel renderings leave.
      #   user channel  (terminal, REPL hints allowed)      -> .user_line
      #   model channel (history XML, tool-oriented)        -> .model_element
      # The event bus stays the transport; this module never touches the bus,
      # shell state, or Loop history — pure functions, hashes in, strings out.
      # The REPL subscriber routes; the Loop drain renders via .history_block.
      module Notices
        module_function

        # Bus event names (single source: Supervisor, Instance and StepRunner
        # emit these, the REPL subscriber listens for them).
        COMPLETED_EVENT = :subagent_completed
        BUDGET_EXHAUSTED_EVENT = :subagent_budget_exhausted
        COMPACTED_EVENT = :subagent_context_compacted

        # Bus event name -> normalized notice kind.
        EVENTS = {
          COMPLETED_EVENT => :completed,
          BUDGET_EXHAUSTED_EVENT => :budget_exhausted,
          COMPACTED_EVENT => :context_compacted
        }.freeze

        # Normalizes a bus payload into the structured notice dialect the Loop
        # queue carries. Unknown events return nil (routed nowhere).
        def normalize(event_name, payload)
          kind = EVENTS[event_name.to_sym]
          return nil unless kind

          notice = { kind: kind, id: payload[:id].to_s, role: payload[:role].to_s,
                     state: payload[:state].to_s, max_steps: payload[:max_steps] }
          # Provider error text entering the notice dialect gets a hard cap:
          # diagnostic color, not payload.
          notice[:reason] = payload[:reason].to_s.slice(0, 120) if kind == :context_compacted
          notice
        end

        # User channel: terminal wording. REPL command syntax is allowed HERE
        # ONLY — never in model_element. The completed event fires for every
        # terminal exit, so the header must reflect the actual state.
        def user_line(notice)
          if notice[:kind] == :context_compacted
            detail = notice[:reason].to_s.empty? ? "" : " (#{notice[:reason]})"
            "🧹 [Subagent Compacted] [#{notice[:id]}] '#{notice[:role]}' recovered from a provider " \
              "context-limit error by compacting its own history; work continues#{detail}."
          elsif notice[:kind] == :budget_exhausted
            "⚠️ [Subagent Paused] [#{notice[:id]}] '#{notice[:role]}' reached step budget " \
              "(#{notice[:max_steps]} steps). Run '!subagents extend #{notice[:id]}' to resume."
          elsif notice[:state] == "failed"
            "❌ [Subagent Failed] [#{notice[:id]}] '#{notice[:role]}' - FAILED. " \
              "Call manage_subagents(action: 'status', conversation_id: '#{notice[:id]}') for the error."
          elsif notice[:state] == "completed"
            "⚡ [Subagent Completed] [#{notice[:id]}] '#{notice[:role]}' - COMPLETED"
          else
            "🏁 [Subagent Finished] [#{notice[:id]}] '#{notice[:role]}' - #{notice[:state].upcase}"
          end
        end

        # Model channel: one self-closing XML element with tool-oriented
        # guidance. Results are deliberately NOT carried — the model retrieves
        # them via manage_subagents (the wait protocol stays authoritative).
        def model_element(notice)
          attrs = { kind: notice[:kind], id: notice[:id], role: notice[:role], state: notice[:state] }
          attrs[:max_steps] = notice[:max_steps] if notice[:kind] == :budget_exhausted
          attrs[:reason] = notice[:reason] if notice[:kind] == :context_compacted && !notice[:reason].to_s.empty?
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
          elsif notice[:kind] == :budget_exhausted
            "Resume via #{extend_budget_hint(notice[:id])} or kill it with action: 'kill'."
          else
            "Retrieve the full result with manage_subagents(action: 'wait', " \
              "conversation_ids: ['#{notice[:id]}'], timeout: 30)."
          end
        end

        # Model/tool-channel tool invocation for resuming a budget-paused
        # subagent. THE single source for this fragment — rendered by the
        # budget guidance here and by the status/wait guidance in
        # tools/builtins/subagent.rb (byte-identical at every site).
        def extend_budget_hint(id, steps: 10)
          "manage_subagents(action: 'extend_budget', conversation_id: '#{id}', steps: #{steps})"
        end
      end
    end
  end
end
