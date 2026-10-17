# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      class UnsatisfiedCoeffectsError < StandardError
        attr_reader :profile_name, :missing

        def initialize(profile_name, missing)
          @profile_name = profile_name.to_s.freeze
          @missing = missing.map { |name| name.to_s.freeze }.freeze
          super("Subagent archetype '#{@profile_name}' requires unsatisfied coeffects: #{@missing.join(', ')}")
        end
      end

      class ReservedProfileError < StandardError; end

      # Per-spawn copy of the profile fields that affect activation and tool
      # visibility. Registry updates replace future snapshots; they never
      # mutate the copy held by an active instance.
      class ProfileSnapshot
        attr_reader :name, :description, :system_prompt, :effective_system_prompt,
                    :requires, :grants, :tool_filter, :custom_prompt, :revision,
                    :profile_version

        def self.capture(type_definition, effective_system_prompt: nil)
          legacy_grants = []
          legacy_grants << "write" if type_definition.enable_write_tools
          legacy_grants << "subagent_spawn" if type_definition.enable_subagent_tools
          grants = type_definition.grants.nil? ? legacy_grants : type_definition.grants

          new(
            name: type_definition.name,
            description: type_definition.description,
            system_prompt: type_definition.system_prompt,
            effective_system_prompt: effective_system_prompt.nil? ? type_definition.system_prompt : effective_system_prompt,
            requires: type_definition.requires || [],
            grants: grants,
            tool_filter: type_definition.tool_filter,
            custom_prompt: type_definition.custom_prompt,
            revision: type_definition.revision
          )
        end

        def initialize(name:, description:, system_prompt:, effective_system_prompt:, requires:, grants:,
                       tool_filter:, custom_prompt:, revision:)
          @name = immutable_string(name)
          @description = immutable_string(description)
          @system_prompt = immutable_string(system_prompt)
          @effective_system_prompt = immutable_string(effective_system_prompt)
          @requires = immutable_list(requires)
          @grants = immutable_list(grants)
          @tool_filter = tool_filter&.freeze
          @custom_prompt = custom_prompt == true
          @revision = revision
          @profile_version = revision || :builtin
          freeze
        end

        private

        def immutable_string(value)
          value.nil? ? nil : value.to_s.dup.freeze
        end

        def immutable_list(values)
          Array(values).map { |value| immutable_string(value) }.freeze
        end
      end
    end
  end
end
