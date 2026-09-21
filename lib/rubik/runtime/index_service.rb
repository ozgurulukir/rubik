# frozen_string_literal: true

require "pathname"
require_relative "../coeffects"
require_relative "service_registration"

module Rubik
  module Runtime
    module IndexService
      module_function

      def register(context_or_manager, index)
        ServiceRegistration.call(context_or_manager) do |ctx|
          next index unless ctx

          ctx.provide(Rubik::Coeffects::CONTEXT_INDEX, index)
          index
        end
      end

      def sync_roots(context_or_manager, index, additional_roots:, ast_graph: nil, cache_store: nil)
        return unless index

        index.additional_roots = Array(additional_roots)
        index.full_scan

        context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)

        if ast_graph
          root_d = index.root_dir

          # Re-index all supported files known to the context index.
          # Rely on File.exist?(full_path) as the sole guard: a file
          # already in the graph simply re-indexes harmlessly.
          index.files.each_key do |rel_file|
            full_path = File.expand_path(rel_file, root_d)
            ext = File.extname(rel_file).downcase
            if defined?(Rubik::AST::Extractor) && Rubik::AST::Extractor.supported_extensions.include?(ext) &&
               File.exist?(full_path)
              ast_graph.index_file(full_path)
            end
          end

          if cache_store && File.directory?(root_d)
            begin
              ast_graph.save_to_cache(cache_store)
            rescue
              nil
            end
          end
        end

        index
      end
    end
  end
end
