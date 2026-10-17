# frozen_string_literal: true

require "monitor"
require_relative "type_definition"
require_relative "profile_contract"
require_relative "builtin_types"
require_relative "dynamic_store"

module Rubik
  module Orchestrator
    module Subagent
      # Catalog of built-in and dynamically synthesized subagent archetypes.
      # Dynamic archetypes are context-scoped, reversible, and tracked by revision.
      class TypeRegistry
        READ_ONLY_TOOLS = BuiltinTypes::READ_ONLY_TOOLS
        CODER_TOOLS = BuiltinTypes::CODER_TOOLS
        SUBAGENT_SPAWN_TOOLS = BuiltinTypes::SUBAGENT_SPAWN_TOOLS
        VAKANUIS_TOOLS = BuiltinTypes::VAKANUIS_TOOLS
        PRUNER_TOOLS = BuiltinTypes::PRUNER_TOOLS

        include DynamicStore

        def initialize(default_context: nil)
          @builtins = {}
          @default_context = default_context
          @monitor = Monitor.new
          init_dynamic_store
          register_default_types
        end

        def register_builtin(type_def)
          @monitor.synchronize { @builtins[type_def.name.to_s.downcase.strip] = type_def }
        end
        private :register_builtin

        def register(type_def, context: nil, replace: false)
          profile = validate_registered_profile(type_def)
          apply_profile_contract(type_def, profile)
          register_dynamic(type_def, context: context || type_def.context || @default_context, replace: replace)
        end

        def get(name)
          clean = name.to_s.downcase.strip
          @monitor.synchronize do
            prune_dead_entries(clean)
            stack = @stacks[clean]
            return stack.last.type_def if stack&.any?

            @builtins[clean]
          end
        end

        def list
          @monitor.synchronize do
            merged = @builtins.dup
            @stacks.each_key do |clean|
              prune_dead_entries(clean)
              stack = @stacks[clean]
              stack&.any? ? merged[clean] = stack.last.type_def : merged.delete(clean)
            end
            merged.values
          end
        end

        def builtin?(name)
          clean = name.to_s.downcase.strip
          @monitor.synchronize { @builtins.key?(clean) }
        end

        def dynamic?(name)
          clean = name.to_s.downcase.strip
          @monitor.synchronize do
            prune_dead_entries(clean)
            stack = @stacks[clean]
            stack&.any? || false
          end
        end

        def revision_for(name)
          clean = name.to_s.downcase.strip
          @monitor.synchronize do
            prune_dead_entries(clean)
            stack = @stacks[clean]
            stack&.last&.revision
          end
        end

        def builtins
          @monitor.synchronize { @builtins.values.dup }
        end

        def dynamics
          @monitor.synchronize do
            @stacks.each_key { |k| prune_dead_entries(k) }
            @stacks.values.map(&:last).compact.map(&:type_def)
          end
        end

        def define_custom(name:, description:, system_prompt:, requires: [], grants: ProfileContract::UNSET,
                          enable_write_tools: nil, enable_subagent_tools: nil,
                          context: nil, ctx: nil, allow_override: false, override: false, replace: false, allow_replace: false)
          owner_ctx = context || ctx || @default_context
          profile = ProfileContract.validate(
            name: name, description: description, system_prompt: system_prompt,
            requires: requires, grants: grants,
            enable_write_tools: enable_write_tools, enable_subagent_tools: enable_subagent_tools,
            reserved_names: builtins.map(&:name), override_requested: allow_override || override
          )
          write_enabled = profile.grants.include?("write")
          spawn_enabled = profile.grants.include?("subagent_spawn")

          type_def = TypeDefinition.new(
            name: profile.name, description: profile.description,
            system_prompt: profile.system_prompt, requires: profile.requires, grants: profile.grants,
            tool_filter: ProfileContract.tool_filter(profile.grants),
            enable_write_tools: write_enabled, enable_subagent_tools: spawn_enabled,
            custom_prompt: true, context: owner_ctx
          )
          register_dynamic(type_def, context: owner_ctx, replace: replace || allow_replace || override)
        end

        def unregister(name)
          clean = name.to_s.downcase.strip
          @monitor.synchronize do
            stack = @stacks[clean]
            return nil unless stack&.any?

            active_reg = stack.last
            type_def = active_reg.type_def
            unregister_dynamic(active_reg)
            type_def
          end
        end

        private

        def register_default_types
          BuiltinTypes.default_definitions(TypeDefinition).each { |type_def| register_builtin(type_def) }
        end

        def validate_registered_profile(type_def)
          unless type_def.instance_of?(TypeDefinition)
            raise ProfileValidationError, [
              { "field" => "profile", "code" => "invalid_type", "message" => "profile must be a TypeDefinition." }
            ]
          end

          has_contract_grants = !type_def.grants.nil?
          write_flag = type_def.enable_write_tools
          spawn_flag = type_def.enable_subagent_tools
          if has_contract_grants
            write_flag = nil if write_flag.nil? || write_flag == Array(type_def.grants).include?("write")
            spawn_flag = nil if spawn_flag.nil? || spawn_flag == Array(type_def.grants).include?("subagent_spawn")
          end
          ProfileContract.validate(
            name: type_def.name, description: type_def.description, system_prompt: type_def.system_prompt,
            requires: type_def.requires || [],
            grants: has_contract_grants ? type_def.grants : ProfileContract::UNSET,
            enable_write_tools: write_flag,
            enable_subagent_tools: spawn_flag,
            reserved_names: builtins.map(&:name)
          )
        end

        def apply_profile_contract(type_def, profile)
          type_def.name = profile.name
          type_def.description = profile.description
          type_def.system_prompt = profile.system_prompt
          type_def.requires = profile.requires
          type_def.grants = profile.grants
          type_def.tool_filter = ProfileContract.tool_filter(profile.grants)
          type_def.enable_write_tools = profile.grants.include?("write")
          type_def.enable_subagent_tools = profile.grants.include?("subagent_spawn")
        end
      end
    end
  end
end
