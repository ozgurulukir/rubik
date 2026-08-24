# frozen_string_literal: true

module Rubik
  module Runtime
    module ASTService
      module_function

      def register(context_or_manager, ast_graph, cache_store: nil)
        ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
        return ast_graph unless ctx

        ctx.provide("ast_graph", ast_graph)
        ctx.provide("ast", ast_graph)

        ctx.on_dispose do
          begin
            ast_graph.save_to_cache(cache_store) if cache_store && ast_graph.respond_to?(:save_to_cache)
          rescue StandardError
            # suppress teardown error
          end
          ast_graph.clear if ast_graph.respond_to?(:clear)
        end

        context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)
        ast_graph
      end
    end
  end
end
