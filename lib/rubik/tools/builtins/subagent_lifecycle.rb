# frozen_string_literal: true

require_relative "../output"
require_relative "../../orchestrator/subagent/budget"
require_relative "../../orchestrator/subagent/notices"
require_relative "../../orchestrator/subagent/narration"

module Rubik
  module Tools
    # Lifecycle actions + guidance renderings for ManageSubagentsTool.
    # Instance-method module on purpose (never a tool class): the builtin
    # registry stays at 31 — redeploy/reap are ACTIONS of manage_subagents.
    module SubagentLifecycle
      # Context-preserving reuse: hand a NEW task to a finished subagent
      # instead of re-spawning and re-explaining (maestro persona workflow).
      def redeploy_action(sup, args)
        id = resolve_id(args)
        return ToolOutput.error("Missing required parameter 'conversation_id' for action 'redeploy'.") if id.empty?

        prompt = (args["prompt"] || args[:prompt]).to_s.strip
        return ToolOutput.error("Missing required parameter 'prompt' (the new task) for action 'redeploy'.") if prompt.empty?

        inst = sup.redeploy(id, prompt: prompt, max_steps: args["steps"] || args[:steps])
        "Redeployed subagent '#{id}' with a new task — context preserved (#{inst.history.size} messages), " \
          "fresh budget: #{inst.max_steps} steps, state: #{inst.state.to_s.upcase}. It runs in the background."
      rescue StandardError => e
        ToolOutput.error(e.message)
      end

      # Diligent cleanup: tombstone every finished subagent NOW (in-memory
      # history reclaimed; durable transcripts and storage index survive).
      def reap_action(sup)
        reaped = sup.reap_finished!(force: true)
        return "No finished subagents to reap." if reaped.empty?

        "Reaped #{reaped.size} finished subagent(s): #{reaped.join(', ')} — in-memory context reclaimed; " \
          "transcripts remain readable via their transcript URIs and rubik://storage search."
      end

      # Blocked states that need maestro action before their chain proceeds
      # (bug-llm-timeout-observability ④): a bare JSON list made a stalled
      # subagent indistinguishable from a healthy one at a glance.
      ATTENTION_STATES = [:paused_error, :waiting_budget, :budget_exhausted, :waiting_input].freeze

      # List with a prominent attention block: any blocked subagent is called
      # out ABOVE the JSON with its state, last error, and the exact recovery
      # action, so a silent stall can't hide inside the pretty-printed rows.
      def list_action(sup)
        instances = sup.list
        return "No active or tracked subagents." if instances.empty?

        lines = []
        attention = instances.select { |i| ATTENTION_STATES.include?(i.state.to_sym) }
        if attention.any?
          lines << "⚠ #{attention.size} subagent(s) need attention:"
          attention.each do |i|
            err = i.last_error.to_s
            # Tail-preserving slice (AutoApply.capped_reason doctrine): OS and
            # provider errors carry the actionable part at the end.
            detail = err.empty? ? "" : " — #{err[-120, 120]}"
            guidance = Rubik::Orchestrator::Subagent::Narration.guidance(i.state, id: i.id, max_steps: i.max_steps) ||
                       "Run manage_subagents(action: 'status', conversation_id: '#{i.id}') for details."
            lines << "  • [#{i.id}] '#{i.role}' — #{i.state.to_s.upcase}#{detail}: #{guidance}"
          end
          lines << ""
        end
        lines << JSON.pretty_generate(instances.map(&:to_h))
        lines.join("\n")
      end
    end
  end
end
