# frozen_string_literal: true

require "json"
require_relative "../base"
require_relative "../output"
require_relative "subagent_lifecycle"
require_relative "../../coeffects"
require_relative "../../orchestrator/subagent/budget"
require_relative "../../orchestrator/subagent/notices"
require_relative "../../orchestrator/subagent/narration"
require_relative "../../orchestrator/subagent/conversation_id"

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

      # Schema truth: document the EFFECTIVE spawn default — the bound
      # supervisor's config-derived value, the Budget invariant otherwise.
      # The literal lives once, here; the static DECLARATION carries the
      # invariant and construction swaps in the supervisor value only when
      # it differs (construction-time snapshot from the kwarg only —
      # deterministic; a runtime-context peek would depend on registration
      # order).
      def self.params_schema_for(steps_default)
        {
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
                  max_steps: { type: "integer", description: "Step budget for subagent execution (default: #{steps_default})" },
                  detach: { type: "boolean", description: "true = this subagent is NOT owned by the current task: a foreground " \
                                                          "interrupt (^C) will not stop it (default: false)" },
                  depends_on: { type: "array", description: "Dispatch constraints: ['subagent-1'] = FS (launch after it completes); " \
                                                            "{'id': 'subagent-1', 'type': 'SS'} = launch when it starts. Queued specs hold no slot until released." }
                },
                required: ["role", "prompt"]
              }
            },
            role: { type: "string", description: "Role for single subagent invocation" },
            prompt: { type: "string", description: "Prompt for single subagent invocation" },
            type_name: { type: "string", description: "Archetype: 'research', 'coder', or 'self'" },
            max_steps: { type: "integer", description: "Step budget for single subagent invocation (default: #{steps_default})" },
            detach: { type: "boolean", description: "true = single-spawn variant of the detach flag above" }
          }
        }
      end

      DECLARATION = Declaration.new(
        name: "invoke_subagent", aliases: ["spawn_subagent", "start_subagent"],
        description: "Invokes one or more subagents asynchronously in disposable sub-contexts.",
        risk: :execute, subagent_spawn: true, maestro_blocked: false, # the delegation verb itself — the gate's whole point
        params_schema: params_schema_for(Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS)
      )
      def initialize(supervisor: nil, runtime_context: nil)
        sup_default = supervisor.respond_to?(:default_max_steps) ? supervisor.default_max_steps : nil
        if sup_default && sup_default != Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS
          super(DECLARATION.with(params_schema: self.class.params_schema_for(sup_default)))
        else
          super(DECLARATION)
        end
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        specs = extract_subagent_specs(args)
        return ToolOutput.error("No valid subagents specified to invoke.") if specs.empty?

        # Task ownership (issue #125): the spawning context's token owns the new
        # work (detached specs opt out per spec). Resolved at call time, so a
        # nested subagent inherits its ancestor's task through its child ctx.
        owner = Rubik::Coeffects.get(@runtime_context, Rubik::Coeffects::TASK_CANCELLATION)

        begin
          results = sup.spawn_batch(specs, owner: owner)
        rescue StandardError => e
          return ToolOutput.error("Failed to invoke subagent(s): #{e.message}")
        end

        launched, queued = results.partition { |outcome, _obj| outcome == :launched }
        lines = ["Launched #{launched.size} background subagent(s):"] +
                launched.map do |_o, i|
                  "  • [#{i.id}] '#{i.role}' (#{i.type_name}) - #{i.state.to_s.upcase} | transcript: #{i.transcript_ref}"
                end
        unless queued.empty?
          rows = queued.map { |_o, s| "  • [#{s.id}] '#{s.role}' - QUEUED (waiting on: #{s.depends_on.join(', ')})" }
          lines << ("\nQueued #{queued.size} subagent(s) on unmet dependencies (no slot, no cost until released): " + rows.join("\n"))
        end
        all_ids = (launched + queued).map { |_o, obj| obj.id }

        lines << "\nSubagents run asynchronously in the background. Conclude your turn to yield the prompt to the user, or call " \
                 "#{Rubik::Orchestrator::Subagent::Notices.wait_hint(all_ids)} only if you strictly need results in this turn (queued ids block until the chain settles)."
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
          model: args["model"] || args[:model] || "inherit", max_steps: args["max_steps"] || args[:max_steps],
          detach: args["detach"] || args[:detach],
          depends_on: args["depends_on"] || args[:depends_on]
        )]
      end

      def normalize_spec(spec)
        spec[:type_name] = spec[:type_name].to_s.strip
        spec[:type_name] = code_modification_prompt?(spec[:role], spec[:prompt]) ? "coder" : "research" if spec[:type_name].empty?
        spec[:max_steps] = spec[:max_steps].to_i if spec[:max_steps] && !spec[:max_steps].to_s.empty?
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
      include SubagentLifecycle

      DECLARATION = Declaration.new(
        name: "manage_subagents", aliases: ["subagents_status", "subagent_list"],
        description: "Manage existing subagents (actions: #{Rubik::Orchestrator::Subagent::Narration.quoted_canonical_list}). " \
                     "Subagents run in background; avoid 'wait' unless strictly blocking.",
        risk: :read,
        params_schema: {
          type: "object",
          properties: {
            action: { type: "string", description: "Action to perform",
                      enum: Rubik::Orchestrator::Subagent::Narration::SCHEMA_ACTIONS },
            timeout: { type: "integer", description: "Max seconds to wait for actions 'wait' or 'status' if running " \
                                                     "(default: #{Rubik::Orchestrator::Subagent::Notices::DEFAULT_WAIT_TIMEOUT} for wait)" },
            conversation_ids: { type: "array", items: { type: "string" }, description: "IDs of subagents to manage/wait" },
            conversation_id: { type: "string", description: "Single subagent ID" },
            run: { type: "integer", description: "Run sequence for action 'result' (default: latest retained run)" },
            cursor: { type: "integer", description: "Character offset for 'result'/'transcript' pagination (default: 0)" },
            limit: { type: "integer", description: "Max characters per page for 'result'/'transcript' " \
                                                   "(defaults: #{Rubik::Orchestrator::Subagent::ResultArchive::DEFAULT_PAGE_CHARS} / " \
                                                   "#{Rubik::Orchestrator::Subagent::TranscriptReader::DEFAULT_PAGE_CHARS})" },
            snapshot: { type: "string", description: "Snapshot token from a previous 'transcript' page — pins the page " \
                                                     "sequence; a transcript changed since that snapshot answers explicitly" },
            prompt: { type: "string", description: "New task text for action 'redeploy'" },
            steps: { type: "integer", description: "Additional steps (extend_budget) or redeploy budget" }
          },
          required: ["action"]
        }
      )
      def initialize(supervisor: nil, runtime_context: nil)
        super(DECLARATION)
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        action = (args["action"] || args[:action] || "list").to_s.downcase.strip
        # Dispatch keys on the canonical form projected from Narration::ACTION_SPECS,
        # so schema enum, help text, and these arms can never drift apart.
        case Rubik::Orchestrator::Subagent::Narration.canonical_action(action)
        when "list"
          list_action(sup)
        when "status"
          id = resolve_id(args)
          return ToolOutput.error("Missing required parameter 'conversation_id' for action 'status'.") if id.empty?

          inst = sup.get(id)
          return ToolOutput.error("Subagent '#{id}' not found.") unless inst

          timeout = (args["timeout"] || args[:timeout]).to_i
          wait_reason = nil
          if timeout.positive? && inst.running?
            outcome = sup.respond_to?(:wait) ? sup.wait([id], timeout: timeout) : nil
            sup.wait_for([id], timeout: timeout) unless outcome
            wait_reason = outcome&.reason
            inst = sup.get(id) || inst
          end

          data = inst.to_h
          data[:wait_reason] = wait_reason if wait_reason
          guidance = Rubik::Orchestrator::Subagent::Narration.guidance(inst.state, id: inst.id, max_steps: inst.max_steps)
          if guidance
            data[:guidance] = guidance
          elsif inst.running?
            data[:guidance] = Rubik::Orchestrator::Subagent::Narration.guidance(
              :running, id: inst.id, max_steps: inst.max_steps, step: inst.current_step, uptime: inst.uptime
            )
          end
          JSON.pretty_generate(data)
        when "wait"
          wait_action(sup, args)
        when "transcript"
          transcript_action(sup, args)
        when "result"
          result_action(sup, args)
        when "extend_budget"
          id = resolve_id(args)
          return ToolOutput.error("Missing required parameter 'conversation_id' for action 'extend_budget'.") if id.empty?

          steps = Rubik::Orchestrator::Subagent::Budget.normalize_grant(args["steps"] || args[:steps])
          if sup.extend_budget(id, steps)
            "Step budget for subagent '#{id}' successfully extended by #{steps} steps (total budget: #{sup.get(id).max_steps}, state: #{sup.get(id).state.to_s.upcase})."
          else
            ToolOutput.error("Subagent '#{id}' not found or cannot extend budget (current state: #{sup.get(id)&.state || 'not found'}).")
          end
        when "resume"
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
        when "redeploy"
          redeploy_action(sup, args)
        when "reap"
          reap_action(sup)
        when "kill"
          ids = resolve_ids(args)
          return ToolOutput.error("Missing required parameter 'conversation_ids' for action 'kill'.#{id_format_hint}") if ids.empty?

          "Killed subagent(s): #{ids.filter_map { |cid| sup.kill(cid, cascade: true) ? cid : nil }.join(', ')}."
        when "kill_all"
          sup.kill_all && "All active subagents have been terminated."
        else
          ToolOutput.error("Unknown manage_subagents action: '#{action}'. Valid: #{Rubik::Orchestrator::Subagent::Narration::CANONICAL_NAMES.join(', ')}.")
        end
      end

      ID_FORMAT_EXAMPLE = "Pass ids as a JSON array (conversation_ids: [\"subagent-5\", \"subagent-6\"]) " \
                          "or a single id (conversation_id: 'subagent-5')."

      private

      def resolve_id(args)
        resolve_ids(args).first.to_s
      end

      # Model-supplied id dialects (JSON array / array-string / comma list /
      # quoted single id) normalize in ConversationId — the parse-side
      # vocabulary shared with send_message.
      def resolve_ids(args)
        raw = args["conversation_ids"] || args[:conversation_ids] ||
              args["conversation_id"] || args[:conversation_id] ||
              args["id"] || args[:id]
        Rubik::Orchestrator::Subagent::ConversationId.normalize_list(raw)
      end

      def id_format_hint
        " #{ID_FORMAT_EXAMPLE}"
      end

      # Wait returning nothing: finished-and-reaped or nonexistent — the
      # supervisor roster is the tiebreaker, so the model gets a correction.
      def unknown_ids_hint(sup, ids)
        known = (sup.respond_to?(:list) ? sup.list : []).map(&:id)
        missing = ids - known
        missing.empty? ? "" : " Unknown id(s): #{missing.join(', ')}.#{id_format_hint}"
      end

      # Truncation hands the model the CANONICAL retained-result reference
      # (issue #122) — a read route that never touches the workspace gate;
      # the live transcript action stays the fallback when no result
      # reference exists. Returns the line WITHOUT indentation.
      def truncated_result_line(res, row)
        return "Result: #{res}" if res.length <= 1500

        ref = row[:result_ref].to_s
        more = ref.empty? ? "manage_subagents(action: 'transcript', conversation_id: '#{row[:id]}')" : "read_file(path: '#{ref}')"
        "Result: #{res[0, 1500]}... [truncated — full result: #{more}]"
      end
    end

    # Tool for dynamically defining a new subagent archetype at runtime (Plan 94).
    class DefineSubagentTool < BaseTool
      include SubagentToolHelpers

      DECLARATION = Declaration.new(
        name: "define_subagent", aliases: ["register_subagent_type", "create_subagent_type"],
        description: "Defines a new archetype of subagent that can be invoked via invoke_subagent.",
        risk: :execute, subagent_spawn: true, maestro_blocked: false, # self-evolution plane (TOOLS.md maestro policy)
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
      def initialize(supervisor: nil, runtime_context: nil)
        super(DECLARATION)
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
