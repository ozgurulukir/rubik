# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Registered archetype representing a subagent role profile, baseline
      # system prompt, capability filtering policies, and lifecycle revision.
      TypeDefinition = Struct.new(
        :name,
        :description,
        :system_prompt,
        :requires, :grants,
        :tool_filter,
        :enable_write_tools, :enable_subagent_tools, :custom_prompt,
        :revision, :context, :handle,
        keyword_init: true
      )

      # Internal tracking struct for a single archetype registration revision.
      Registration = Struct.new(:revision, :name, :type_def, :handle, :context, :active, keyword_init: true)

      # Handle returned by dynamic archetype registration, allowing explicit
      # reversible cleanup and exposing lifecycle revision metadata. Delegates
      # all profile properties to the underlying TypeDefinition.
      class RegistrationHandle
        attr_reader :revision, :type_def, :context, :registry, :name

        def initialize(revision:, type_def:, context:, registry:)
          @revision = revision
          @type_def = type_def
          @context = context
          @registry = registry
          @name = type_def.name
          @active = true
        end

        def active?
          @active
        end

        def undo
          return false unless @active

          @registry.unregister_dynamic(self)
        end
        alias unregister undo

        def to_type_def
          @type_def
        end

        def handle
          self
        end

        def description = @type_def.description
        def system_prompt = @type_def.system_prompt
        def tool_filter = @type_def.tool_filter
        def requires = @type_def.requires
        def grants = @type_def.grants
        def enable_write_tools = @type_def.enable_write_tools
        def enable_subagent_tools = @type_def.enable_subagent_tools
        def custom_prompt = @type_def.custom_prompt

        def is_a?(klass)
          klass == TypeDefinition || klass == RegistrationHandle || super
        end
        alias kind_of? is_a?

        def respond_to_missing?(mid, include_private = false)
          @type_def.respond_to?(mid, include_private) || super
        end

        def method_missing(mid, *, &)
          if @type_def.respond_to?(mid)
            @type_def.public_send(mid, *, &)
          else
            super
          end
        end
      end
    end
  end
end
