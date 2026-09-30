# frozen_string_literal: true

require "json"
require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"
require_relative "../../orchestrator/subagent/budget"
require_relative "../../orchestrator/subagent/notices"

module Rubik
  module Tools
    # Helper extracting SubagentSupervisor instance from constructor or runtime context.
    module SubagentToolHelpers
      def resolve_supervisor(supervisor, runtime_context)
        return supervisor if supervisor
        return nil unless runtime_context.respond_to?(:get)

        Rubik::Coeffects.get(runtime_context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
      end
    end

    # Tool for asynchronously spawning one or more isolated subagents (Plan 94).
    class InvokeSubagentTool < BaseTool
      include SubagentToolHelpers

      def initialize(supervisor: nil, runtime_context: nil)
        # Schema truth: document the EFFECTIVE spawn default — the bound
        # supervisor's config-derived value, the Budget invariant otherwise.
        # Construction-time snapshot from the kwarg only (deterministic; a
        # runtime-context peek would depend on registration order).
        sup_default = supervisor.respond_to?(:default_max_steps) ? supervisor.default_max_steps : nil
        steps_default = sup_default || Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS
        super(
          name: "invoke_subagent",
          aliases: ["spawn_subagent", "start_subagent"],
          description: "Invokes one or more subagents asynchronously in disposable sub-contexts.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              subagents: {
                type: "array", description: "Array of subagents to launch concurrently",
                items: {
                  type: "object",
                  properties: {
                    type_name: { type: "string", description: "Archetype: 'research' (default), 'coder', 'self', or custom" },
                    role: { type: "string", description: "2-5 word job title" },
                    prompt: { type: "string", description: "Actionable task description" },
                    system_prompt: { type: "string", description: "Optional custom system prompt" },
                    workspace: { type: "string", enum: ["inherit", "branch", "share"], description: "Isolation mode" },
                    model: { type: "string", enum: ["inherit", "flash_lite", "flash", "pro"], description: "Model tier" },
                    max_steps: { type: "integer", description: "Step budget for subagent execution (default: #{steps_default})" }
                  },
                  required: ["role", "prompt"]
                }
              },
              role: { type: "string", description: "Role for single subagent invocation" },
              prompt: { type: "string", description: "Prompt for single subagent invocation" },
              type_name: { type: "string", description: "Archetype: 'research', 'coder', or 'self'" },
              max_steps: { type: "integer", description: "Step budget for single subagent invocation (default: #{steps_default})" }
            }
          }
        )
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        specs = extract_subagent_specs(args)
        return ToolOutput.error("No valid subagents specified to invoke.") if specs.empty?

        launched = []
        specs.each do |s|
          launched << sup.spawn(
            type_name: s[:type_name], role: s[:role], prompt: s[:prompt],
            system_prompt: s[:system_prompt], workspace: s[:workspace] || "inherit",
            model: s[:model] || "inherit", max_steps: s[:max_steps]
          )
        rescue StandardError => e
          return ToolOutput.error("Failed to spawn subagent '#{s[:role]}': #{e.message}")
        end

        lines = ["Launched #{launched.size} background subagent(s):"] +
                launched.map { |i| "  • [#{i.id}] '#{i.role}' (#{i.type_name}) - #{i.state.to_s.upcase}" }
        lines << "\nSubagents run asynchronously in the background. Conclude your turn to yield the prompt to the user, or " \
                 "call #{Rubik::Orchestrator::Subagent::Notices.wait_hint(launched.map(&:id))} only if you strictly need results in this turn."
        lines.join("\n")
      end

      private

      def extract_subagent_specs(args)
        list = args["subagents"] || args[:subagents]
        return list.map { |item| normalize_spec(symbolize_keys(item)) } if list.is_a?(Array) && !list.empty?

        role = args["role"] || args[:role]
        prompt = args["prompt"] || args[:prompt]
        return [] unless role && prompt

        [normalize_spec(
          type_name: args["type_name"] || args[:type_name], role: role, prompt: prompt,
          system_prompt: args["system_prompt"] || args[:system_prompt], workspace: args["workspace"] || args[:workspace] || "inherit",
          model: args["model"] || args[:model] || "inherit", max_steps: args["max_steps"] || args[:max_steps]
        )]
      end

      def normalize_spec(spec)
        spec[:type_name] = spec[:type_name].to_s.strip
        spec[:type_name] = code_modification_prompt?(spec[:role], spec[:prompt]) ? "coder" : "research" if spec[:type_name].empty?
        steps = spec[:max_steps]
        spec[:max_steps] = steps.to_i if steps && !steps.to_s.empty?
        spec
      end

      def code_modification_prompt?(role, prompt)
        "#{role} #{prompt}".match?(/\b(fix|patch|implement|refactor|write|create|modify|edit|debug)\b/i)
      end

      def symbolize_keys(hash)
        hash.is_a?(Hash) ? hash.transform_keys(&:to_sym) : {}
      end
    end

    # Tool for listing, inspecting, or canceling running subagents (Plan 94).
    class ManageSubagentsTool < BaseTool
      include SubagentToolHelpers

      def initialize(supervisor: nil, runtime_context: nil)
        wait_default = Rubik::Orchestrator::Subagent::Notices::DEFAULT_WAIT_TIMEOUT
        super(
          name: "manage_subagents",
          aliases: ["subagents_status", "subagent_list"],
          description: "Manage existing subagents (actions: 'list', 'status', 'wait', 'transcript', 'extend_budget', 'resume', 'kill', 'kill_all'). " \
                       "Subagents run in background; avoid 'wait' unless strictly blocking.",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              action: { type: "string", description: "Action to perform",
                        enum: ["list", "status", "wait", "transcript", "extend_budget",
                               "grant_steps", "extend", "resume", "retry", "kill", "kill_all"] },
              timeout: { type: "integer", description: "Max seconds to wait for actions 'wait' or 'status' if running (default: #{wait_default} for wait)" },
              conversation_ids: { type: "array", items: { type: "string" }, description: "IDs of subagents to manage/wait" },
              conversation_id: { type: "string", description: "Single subagent ID" },
              steps: { type: "integer", description: "Number of additional steps to grant (for extend_budget)" }
            },
            required: ["action"]
          }
        )
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        action = (args["action"] || args[:action] || "list").to_s.downcase.strip
        case action
        when "list"
          instances = sup.list
          return "No active or tracked subagents." if instances.empty?

          JSON.pretty_generate(instances.map(&:to_h))
        when "status"
          id = resolve_id(args)
          return ToolOutput.error("Missing required parameter 'conversation_id' for action 'status'.") if id.empty?

          inst = sup.get(id)
          return ToolOutput.error("Subagent '#{id}' not found.") unless inst

          timeout = (args["timeout"] || args[:timeout]).to_i
          if timeout.positive? && inst.running?
            sup.wait_for([id], timeout: timeout)
            inst = sup.get(id) || inst
          end

          data = inst.to_h
          guidance = budget_guidance(inst.state, inst.id, inst.max_steps)
          if guidance
            data[:guidance] = guidance
          elsif inst.running?
            data[:guidance] = "Subagent is actively working (step #{inst.current_step}/#{inst.max_steps}, #{inst.uptime.round(1)}s uptime). " \
                              "DO NOT poll 'status' in a loop! Call #{Rubik::Orchestrator::Subagent::Notices.wait_any_hint} to block until completion, " \
                              "or simply stop calling tools to receive reactive wakeup."
          end
          JSON.pretty_generate(data)
        when "wait"
          timeout = [(args["timeout"] || args[:timeout] || Rubik::Orchestrator::Subagent::Notices::DEFAULT_WAIT_TIMEOUT).to_i, 1].max
          ids = Array(args["conversation_ids"] || args[:conversation_ids] || args["conversation_id"] || args[:conversation_id]).compact
          results = sup.wait_for(ids, timeout: timeout)
          return "No active subagents to wait for." if results.empty?

          lines = ["Subagents wait finished (#{results.size} tracked):"]
          results.each do |r|
            lines << "  • [#{r[:id]}] '#{r[:role]}' (#{r[:type]}) - #{r[:state].to_s.upcase}"
            res = (r[:result] || r[:result_summary]).to_s.strip
            lines << (res.length > 1500 ? "    Result: #{res[0, 1500]}... (use action: 'transcript')" : "    Result: #{res}") unless res.empty?
            lines << "    Guidance: #{guidance}" if (guidance = budget_guidance(r[:state], r[:id], r[:max_steps]))
          end
          lines.join("\n")
        when "transcript"
          id = resolve_id(args)
          return ToolOutput.error("Missing required parameter 'conversation_id' for action 'transcript'.") if id.empty?

          inst = sup.get(id)
          return ToolOutput.error("Subagent '#{id}' not found.") unless inst

          inst.format_transcript
        when "extend_budget", "grant_steps", "extend"
          id = resolve_id(args)
          return ToolOutput.error("Missing required parameter 'conversation_id' for action 'extend_budget'.") if id.empty?

          steps = Rubik::Orchestrator::Subagent::Budget.normalize_grant(args["steps"] || args[:steps])
          if sup.extend_budget(id, steps)
            "Step budget for subagent '#{id}' successfully extended by #{steps} steps (total budget: #{sup.get(id).max_steps}, state: #{sup.get(id).state.to_s.upcase})."
          else
            ToolOutput.error("Subagent '#{id}' not found or cannot extend budget (current state: #{sup.get(id)&.state || 'not found'}).")
          end
        when "resume", "retry"
          id = resolve_id(args)
          if id.empty?
            resumed = sup.resume_all
            return resumed.empty? ? "No paused subagents to resume." : "Resumed subagent(s): #{resumed.join(', ')}."
          end

          if sup.resume(id, additional_steps: args["steps"] || args[:steps])
            "Subagent '#{id}' successfully resumed (state: #{sup.get(id).state.to_s.upcase})."
          else
            ToolOutput.error("Subagent '#{id}' cannot be resumed (current state: #{sup.get(id)&.state || 'not found'}).")
          end
        when "kill"
          ids = Array(args["conversation_ids"] || args[:conversation_ids] || args["conversation_id"] || args[:conversation_id]).compact
          return ToolOutput.error("Missing required parameter 'conversation_ids' for action 'kill'.") if ids.empty?

          "Killed subagent(s): #{ids.map { |cid| sup.kill(cid, cascade: true) ? cid : nil }.compact.join(', ')}."
        when "kill_all", "killall"
          sup.kill_all && "All active subagents have been terminated."
        else
          ToolOutput.error("Unknown manage_subagents action: '#{action}'. Valid: list, status, wait, transcript, extend_budget, resume, kill, kill_all.")
        end
      end

      private

      # Shared budget-state dispatch for status/wait renderings; nil = no story.
      def budget_guidance(state, id, max_steps)
        case state.to_s
        when "waiting_input" then "Subagent asked a question and is BLOCKED awaiting your answer. Reply via send_message(recipient: '#{id}', message: '<your answer>')."
        when "waiting_budget" then Rubik::Orchestrator::Subagent::Notices.budget_paused_line(id, max_steps)
        when "budget_exhausted" then Rubik::Orchestrator::Subagent::Notices.budget_exhausted_line(max_steps)
        when "paused_error" then "Subagent paused on provider/network error. Call manage_subagents(action: 'resume', conversation_id: '#{id}') to retry."
        end
      end

      def resolve_id(args)
        (args["conversation_id"] || args[:conversation_id] || args["id"] || args[:id] || (args["conversation_ids"] || args[:conversation_ids])&.first).to_s.strip
      end
    end

    # Tool for inter-agent messaging between supervisor and subagents (Plan 94).
    class SendMessageTool < BaseTool
      include SubagentToolHelpers

      def initialize(supervisor: nil, runtime_context: nil)
        super(
          name: "send_message",
          aliases: ["msg_agent", "tell_subagent"],
          description: "Send a message or instruction to another agent or subagent by its conversation ID.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              recipient: { type: "string", description: "The recipient subagent conversation ID (e.g. 'subagent-1')" },
              message: { type: "string", description: "The message content to deliver" },
              steps: { type: "integer", description: "Optional additional step budget to grant alongside message" }
            },
            required: ["recipient", "message"]
          }
        )
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        recipient = (args["recipient"] || args[:recipient]).to_s.strip
        msg = (args["message"] || args[:message]).to_s.strip
        return ToolOutput.error("Missing required parameter 'recipient'.") if recipient.empty?
        return ToolOutput.error("Missing required parameter 'message'.") if msg.empty?

        return "Message successfully delivered to subagent '#{recipient}'." if sup.send_message(recipient, msg, additional_steps: args["steps"] || args[:steps])

        ToolOutput.error("Subagent '#{recipient}' not found or no longer active.")
      end
    end

    # Tool for dynamically defining a new subagent archetype at runtime (Plan 94).
    class DefineSubagentTool < BaseTool
      include SubagentToolHelpers

      def initialize(supervisor: nil, runtime_context: nil)
        super(
          name: "define_subagent",
          aliases: ["register_subagent_type", "create_subagent_type"],
          description: "Defines a new archetype of subagent that can be invoked via invoke_subagent.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Unique name for archetype" },
              description: { type: "string", description: "Human-readable description" },
              system_prompt: { type: "string", description: "Detailed system prompt" },
              enable_write_tools: { type: "boolean", description: "Equip subagent with write tools (default: false)" },
              enable_subagent_tools: { type: "boolean", description: "Allow subagent to spawn subagents (default: false)" }
            },
            required: ["name", "description", "system_prompt"]
          }
        )
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        name = (args["name"] || args[:name]).to_s.strip
        desc = (args["description"] || args[:description]).to_s.strip
        prompt = (args["system_prompt"] || args[:system_prompt]).to_s.strip
        return ToolOutput.error("Parameters 'name', 'description', and 'system_prompt' are required.") if name.empty? || desc.empty? || prompt.empty?

        type_def = sup.type_registry.define_custom(
          name: name, description: desc, system_prompt: prompt,
          enable_write_tools: args["enable_write_tools"] || args[:enable_write_tools] || false,
          enable_subagent_tools: args["enable_subagent_tools"] || args[:enable_subagent_tools] || false
        )

        "Subagent archetype '#{type_def.name}' successfully defined and available for invoke_subagent."
      end
    end
  end
end
