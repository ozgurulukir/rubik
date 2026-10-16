# frozen_string_literal: true

require "monitor"
require_relative "type_definition"
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

        def register(type_def, builtin: false)
          if builtin || !type_def.custom_prompt
            register_builtin(type_def)
          else
            register_dynamic(type_def, context: type_def.context)
          end
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

        def define_custom(name:, description:, system_prompt:, enable_write_tools: false, enable_subagent_tools: false,
                          context: nil, ctx: nil, allow_override: false, override: false, replace: false, allow_replace: false)
          clean_name = name.to_s.downcase.strip
          raise ArgumentError, "Subagent type name cannot be empty" if clean_name.empty?

          owner_ctx = context || ctx || @default_context
          if owner_ctx&.respond_to?(:disposed?) && owner_ctx.disposed?
            raise ArgumentError, "Cannot define archetype '#{clean_name}' in a disposed context. To fix, use an active context or omit context."
          end

          if builtin?(clean_name) && !(allow_override || override)
            raise ArgumentError, "Cannot define archetype '#{clean_name}' because it would override a built-in archetype. To fix, choose a different name or specify allow_override: true."
          end

          if dynamic?(clean_name) && !(replace || allow_replace || override)
            raise ArgumentError, "Cannot define archetype '#{clean_name}' because it is already registered. To fix, choose a different name or specify replace: true."
          end

          filter = lambda do |tool_name|
            return false if !enable_subagent_tools && SUBAGENT_SPAWN_TOOLS.include?(tool_name)
            return false if !enable_write_tools && Rubik::Tools::Catalog.write_grant_tools.include?(tool_name)

            true
          end

          type_def = TypeDefinition.new(
            name: clean_name, description: description.to_s.strip,
            system_prompt: system_prompt.to_s.strip, tool_filter: filter,
            enable_write_tools: enable_write_tools, enable_subagent_tools: enable_subagent_tools,
            custom_prompt: true, context: owner_ctx
          )
          register_dynamic(type_def, context: owner_ctx)
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
      end
    end
  end
end
