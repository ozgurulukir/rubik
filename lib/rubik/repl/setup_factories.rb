# frozen_string_literal: true

module Rubik
  module REPL
    # Öneri 3 (Kademe 3): Shell'den ayrılan kurulum fabrikaları. build_tool_registry
    # default araç kaydını enjekte edilen alt sistemlerle kurar; orchestrator_loop
    # aktif loop fiber'ını erişir (yoksa / farklı opts ile yeniden kurar);
    # build_orchestrator_loop route/provider çözümlemesiyle LoopService.build_loop
    # fabrikasını çalıştırır.
    # Durum Shell'de yaşar (@buffer_manager, @context_index, @ast_graph,
    # @adapter_registry, @guard, @sandbox_runner, @overlay_storage,
    # @runtime_manager, @lsp_manager, @config, @router); mixin yalnızca
    # fabrika politikasını kodlar.
    module SetupFactories
      # Öneri 3 (Kademe 3): build_tool_registry / orchestrator_loop /
      # build_orchestrator_loop, lib/rubik/repl/setup_factories.rb mixin'ine
      # taşındı (araç kaydı kurulumu ve orchestrator loop fabrikaları).

      def build_tool_registry
        Rubik::Tools::Registry.build_default(
          buffer_manager: @buffer_manager, context_index: @context_index, ast_graph: @ast_graph,
          adapter_registry: @adapter_registry, guard: @guard,
          sandbox_runner: @sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: @config),
          shell: self, overlay_storage: @overlay_storage, runtime_manager: @runtime_manager,
          lsp_manager: @lsp_manager, task_manager: @task_manager, config: @config, root_dir: Dir.pwd
        )
      end

      def orchestrator_loop(opts = {})
        fiber = @runtime_manager&.fibers&.[]("orchestrator_loop")
        return fiber.instance if fiber && fiber.state == :active && fiber.instance && opts.empty?

        build_orchestrator_loop(opts)
      end

      def build_orchestrator_loop(opts = {})
        routed = if opts[:provider]
                   nil
                 else
                   begin
                     @router.route(task_type: opts[:task_type] || :auto, prompt: opts[:prompt])
                   rescue
                     nil
                   end
                 end
        provider = opts[:provider] || routed&.fetch(:provider, nil) ||
                   (@runtime_manager&.context.respond_to?(:get) ? Rubik::Coeffects.get(@runtime_manager.context, Rubik::Coeffects::LLM_CLIENT) : nil)
        return nil unless provider

        merged = opts.merge(
          provider: provider,
          model: opts[:model] || routed&.fetch(:model, nil),
          context_limit: opts[:context_limit] || routed&.fetch(:context_limit, nil),
          max_output_tokens: opts[:max_output_tokens] || routed&.fetch(:max_output_tokens, nil)
        )
        Rubik::Runtime::LoopService.build_loop(@runtime_manager&.context, shell: self, config: merged)
      end
    end
  end
end
