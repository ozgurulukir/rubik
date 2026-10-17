# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../orchestrator/subagent/profile_contract"
require_relative "subagent"

module Rubik
  module Tools
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
            name: { type: "string", maxLength: Rubik::Orchestrator::Subagent::ProfileContract::FIELD_LIMITS.fetch(:name),
                    description: "Unique name for archetype" },
            description: { type: "string", maxLength: Rubik::Orchestrator::Subagent::ProfileContract::FIELD_LIMITS.fetch(:description),
                           description: "Human-readable description" },
            system_prompt: { type: "string", maxLength: Rubik::Orchestrator::Subagent::ProfileContract::FIELD_LIMITS.fetch(:system_prompt),
                             description: "Detailed system prompt" },
            requires: { type: "array", maxItems: Rubik::Orchestrator::Subagent::ProfileContract::MAX_COEFFECTS,
                        items: { type: "string", maxLength: Rubik::Orchestrator::Subagent::ProfileContract::MAX_COEFFECT_LENGTH },
                        description: "Runtime coeffect keys required by this profile" },
            grants: { type: "array", maxItems: Rubik::Orchestrator::Subagent::ProfileContract::MAX_GRANTS,
                      items: { type: "string", enum: Rubik::Orchestrator::Subagent::ProfileContract::CAPABILITY_GRANTS },
                      description: "Optional capabilities: write and subagent_spawn (default: none)" },
            replace: { type: "boolean", description: "Explicitly allow replacing an existing dynamic archetype (default: false)" }
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

        argument = ->(key) { args.key?(key.to_s) ? args[key.to_s] : args[key.to_sym] }
        provided = ->(key) { args.key?(key.to_s) || args.key?(key.to_sym) }

        owner_ctx = @runtime_context || (sup.respond_to?(:root_context) ? sup.root_context : nil)
        kwargs = {
          name: argument.call(:name), description: argument.call(:description),
          system_prompt: argument.call(:system_prompt), replace: argument.call(:replace) || false
        }
        [:requires, :grants, :enable_write_tools, :enable_subagent_tools].each do |key|
          kwargs[key] = argument.call(key) if provided.call(key)
        end
        kwargs[:context] = owner_ctx if owner_ctx

        type_def = sup.type_registry.define_custom(**kwargs)
        "Subagent archetype '#{type_def.name}' successfully defined and available for invoke_subagent."
      rescue ArgumentError => e
        ToolOutput.error(e.message)
      end
    end
  end
end
