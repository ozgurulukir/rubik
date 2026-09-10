# frozen_string_literal: true

require_relative "../ast"

module Rubik
  module Runtime
    module ASTService
      module_function

      def register(context_or_manager, ast_graph, cache_store: nil)
        ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
        return ast_graph unless ctx

        ctx.provide("ast_graph", ast_graph)

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

      # Drop graph entries for files inside the project root that the context
      # scanner no longer reports — e.g. subtrees that became covered by an
      # ignore rule (the scanner's whole-subtree pruning is stronger than the
      # legacy one-level fnmatch filter). Without this, symbols loaded from a
      # pre-upgrade cache would linger in the graph and be re-saved forever.
      # Guarded on a non-empty scan so a failed scan can never wipe the graph.
      # Files outside the primary root (additional roots, external dirs) are
      # untouched: the context index may not cover them.
      # Returns the number of purged entries.
      def purge_stale_entries!(ast_graph, context_index, root_dir)
        files = context_index.files
        return 0 if files.empty?

        root_prefix = "#{root_dir.to_s.tr('\\', '/')}/"
        supported = Rubik::AST::Extractor.supported_extensions
        stale = []

        ast_graph.file_symbols.each_key do |path|
          norm = path.to_s.tr("\\", "/")
          next unless norm.start_with?(root_prefix)

          rel = norm[root_prefix.length..]
          stale << path if supported.include?(File.extname(rel).downcase) && !files.key?(rel)
        end

        stale.each { |path| ast_graph.remove_file(path) }
        stale.size
      end
    end
  end
end
