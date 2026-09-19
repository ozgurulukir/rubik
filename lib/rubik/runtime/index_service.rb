# frozen_string_literal: true

require "pathname"

module Rubik
  module Runtime
    module IndexService
      module_function

      def register(context_or_manager, index)
        ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
        return index unless ctx

        ctx.provide("context_index", index)

        context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)
        index
      end

      def sync_roots(context_or_manager, index, additional_roots:, ast_graph: nil, cache_store: nil)
        return unless index

        index.additional_roots = Array(additional_roots)
        index.full_scan

        context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)

        if ast_graph
          root_d = index.root_dir
          indexed_files = ast_graph.file_symbols.keys

          # indexed_files holds full paths, but rel_file (and even full_path here) is
          # a fresh path we are about to index; the redundant membership guard did
          # not do what its comment claimed, so rely on File.exist?(full_path) as the
          # sole guard: a file already in the graph simply re-indexes harmlessly.
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
