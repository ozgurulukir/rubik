# frozen_string_literal: true

require_relative "fiber"

module Rubik
  module Runtime
    class AgentLoopFiber < Fiber
      attr_reader :shell

      def initialize(name: "orchestrator_loop", inject: %w[llm_client tool_registry buffer_manager], config: {}, shell: nil, &factory)
        @shell = shell
        super(name: name, inject: inject, config: config, &factory)
      end

      def build_instance(sub_context, config)
        LoopService.build_loop(sub_context, shell: @shell, config: config)
      end
    end

    module LoopService
      module_function

      def register(runtime_manager_or_context, shell: nil, name: "orchestrator_loop", inject: %w[llm_client tool_registry buffer_manager], config: {})
        fiber = AgentLoopFiber.new(name: name, inject: inject, config: config, shell: shell)
        if runtime_manager_or_context.respond_to?(:register_fiber)
          runtime_manager_or_context.register_fiber(fiber)
        else
          ctx = runtime_manager_or_context.respond_to?(:context) ? runtime_manager_or_context.context : runtime_manager_or_context
          fiber.activate!(ctx) if ctx && fiber.satisfiable?(ctx)
        end
        fiber
      end

      def build_loop(context, shell: nil, config: {})
        ctx = context.respond_to?(:context) ? context.context : context
        provider = config[:provider] || (ctx.respond_to?(:get) ? (ctx.get("llm_client") || ctx.get("llm")) : nil)
        tool_registry = config[:tool_registry] || (ctx.respond_to?(:get) ? (ctx.get("tool_registry") || ctx.get("tools")) : nil) || shell&.build_tool_registry
        app_config = config[:config] || shell&.config || (ctx.respond_to?(:get) ? ctx.get("config") : nil)

        max_steps = config[:max_steps] || (app_config.respond_to?(:fetch) ? app_config.fetch("agent.max_steps", 40).to_i : 40)
        warn_ratio = config[:warn_at_ratio] || (app_config.respond_to?(:fetch) ? app_config.fetch("agent.warn_at_ratio", 0.75).to_f : 0.75)
        model = config[:model]
        on_step = config[:on_step]
        context_limit = config[:context_limit]
        max_output_tokens = config[:max_output_tokens]

        require_relative "../orchestrator"

        Rubik::Orchestrator::Loop.new(
          provider: provider,
          tool_registry: tool_registry,
          max_steps: max_steps,
          warn_at_ratio: warn_ratio,
          model: model,
          shell: shell,
          context_limit: context_limit,
          max_output_tokens: max_output_tokens,
          on_step: on_step
        )
      end
    end
  end
end
