# frozen_string_literal: true

module Rubik
  module REPL
    # Öneri 3 (Kademe 4): Shell'den ayrılan AST ısınma bloğu. warm_ast_graph
    # ısınmayı senkron ya da arka plan thread'inde tetikler; stop_background_indexer
    # ve join_indexer_safely indexer thread'inin çökmesiz teardown'unu (Audit 1)
    # sağlar; perform_warm_ast_graph delta tarama → indeksleme → stale temizliği →
    # cache kalıcılığı zincirini yürütür.
    # Durum Shell'de yaşar (@indexer_thread, @buffer_manager, @context_index,
    # @ast_graph, @cache_store, @logger, @event_bus); mixin yalnızca ısınma
    # politikasını kodlar.
    module AstWarmup
      # Öneri 3 (Kademe 4): warm_ast_graph / stop_background_indexer /
      # join_indexer_safely / perform_warm_ast_graph,
      # lib/rubik/repl/ast_warmup.rb mixin'ine taşındı (AST grafiği ısınma ve
      # arka plan indexer yaşam döngüsü).

      def warm_ast_graph(async: true)
        if async
          stop_background_indexer
          # Reset the cooperative-stop flag so repeated warm cycles behave the
          # same as the first (per-turn scopes, MCP reconnects, tool epochs).
          @indexer_stop_requested = false
          warmup_token = @ast_graph.begin_warmup if @ast_graph&.respond_to?(:begin_warmup)
          @indexer_thread = Thread.new do
            Thread.current[:rubik_ast_warmup_token] = warmup_token
            perform_warm_ast_graph
          rescue StandardError => e
            @ast_graph.finish_warmup(warmup_token, state: :failed) if warmup_token
            @logger&.warn("AST graph background indexer thread error: #{e.class}: #{e.message}")
          ensure
            Thread.current[:rubik_ast_warmup_token] = nil
          end
          ctx = @runtime_manager&.context || (respond_to?(:context) ? context : nil)
          if ctx.respond_to?(:register_disposable) && ctx != @indexer_disposable_ctx
            @indexer_disposable_ctx = ctx
            ctx.register_disposable { stop_background_indexer }
          end
        else
          @indexer_stop_requested = false
          warmup_token = @ast_graph.begin_warmup if @ast_graph&.respond_to?(:begin_warmup)
          previous_token = Thread.current[:rubik_ast_warmup_token]
          Thread.current[:rubik_ast_warmup_token] = warmup_token
          begin
            perform_warm_ast_graph
          ensure
            Thread.current[:rubik_ast_warmup_token] = previous_token
            @ast_graph.finish_warmup(warmup_token) if warmup_token
          end
        end
      end

      # Single-homed "workspace roots changed → resync index → re-warm AST"
      # sequence (formerly hand-wired in !workspace add/remove and reactive
      # config wiring). sync_roots already performs additional_roots= +
      # full_scan + fiber reconcile; the sync re-warm keeps symbols fresh
      # before control returns to the caller.
      def sync_workspace_index!
        return unless @context_index

        Rubik::Runtime::IndexService.sync_roots(
          @runtime_manager, @context_index,
          additional_roots: @buffer_manager&.additional_roots,
          ast_graph: @ast_graph, cache_store: @cache_store
        )
        warm_ast_graph(async: false)
      end

      # Audit 1: teardown/join of the background indexer never crashes shutdown
      # or blocks symbol lookups; detail surfaced via debug_warn. The bounded
      # join mechanics live in Concurrency::Join; the failure log channel
      # stays here.
      #
      # Cooperative cancellation, NOT Thread#kill: a one-shot warm cycle may run
      # perform_warm_ast_graph's delta-scan -> index -> purge -> save_to_cache
      # chain, and #kill would abort it between save_to_cache and completion,
      # leaving a partially written / inconsistent cache (AGENTS.md §5 leaked
      # side-effects + partial-write). The worker checks @indexer_stop_requested
      # before committing the cache; here we only request + graceful-join.
      def stop_background_indexer
        return unless @indexer_thread

        @indexer_stop_requested = true
        join_indexer_safely
        @indexer_thread = nil unless @indexer_thread&.alive?
      rescue StandardError => e
        debug_warn("Background AST indexer teardown failed: #{e.class}: #{e.message}")
        nil
      end

      def join_indexer_safely(timeout = nil)
        result = Rubik::Concurrency::Join.thread(@indexer_thread, timeout: timeout)
        debug_warn("Background AST indexer join failed: #{result.class}: #{result.message}") if result.is_a?(StandardError)
        nil
      end

      def perform_warm_ast_graph
        warmup_token = Thread.current[:rubik_ast_warmup_token]
        warmup_token ||= @ast_graph.begin_warmup if @ast_graph&.respond_to?(:begin_warmup)
        warmup_state = :ready
        root_d = @buffer_manager&.root_dir || Dir.pwd
        delta = @context_index.incremental_scan
        indexed_files = @ast_graph.file_symbols.keys

        files_to_index = (delta[:added] + delta[:modified]).dup

        @context_index.files.each_key do |rel_file|
          break if @indexer_stop_requested

          full_path = File.join(root_d, rel_file)
          ext = File.extname(rel_file).downcase
          files_to_index << rel_file if Rubik::AST::Extractor.supported_extensions.include?(ext) && !(indexed_files.include?(full_path) || indexed_files.include?(rel_file))
        end

        files_to_process = files_to_index.uniq.select do |rel_file|
          ext = File.extname(rel_file).downcase
          Rubik::AST::Extractor.supported_extensions.include?(ext) && File.exist?(File.join(root_d, rel_file))
        end
        total_operations = files_to_process.length + delta[:deleted].length
        @ast_graph.update_warmup(warmup_token, indexed: 0, total: total_operations) if warmup_token
        completed_operations = 0

        files_to_process.each do |rel_file|
          break if @indexer_stop_requested

          full_path = File.join(root_d, rel_file)
          @ast_graph.index_file(full_path)
          completed_operations += 1
          @ast_graph.update_warmup(warmup_token, indexed: completed_operations, total: total_operations) if warmup_token
        end

        delta[:deleted].each do |rel_file|
          break if @indexer_stop_requested

          full_path = File.join(root_d, rel_file)
          @ast_graph.remove_file(full_path)
          completed_operations += 1
          @ast_graph.update_warmup(warmup_token, indexed: completed_operations, total: total_operations) if warmup_token
        end

        return if @indexer_stop_requested

        purged = Rubik::Runtime::ASTService.purge_stale_entries!(@ast_graph, @context_index, root_d)

        if @cache_store && File.directory?(root_d) && !@indexer_stop_requested &&
           (!files_to_index.empty? || !delta[:deleted].empty? || purged.positive?)
          @ast_graph.save_to_cache(@cache_store)
        end
      rescue StandardError => e
        warmup_state = :failed
        @logger&.warn("AST graph warm failed: #{e.message}")
        @event_bus&.emit(:ast_warm_failed, error: e.message)
        nil
      ensure
        @ast_graph.finish_warmup(warmup_token, state: warmup_state) if warmup_token
      end
    end
  end
end
