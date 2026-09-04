# frozen_string_literal: true

module Rubik
  module REPL
    # Wires reactive configuration observers to Shell subsystems.
    # Returns an array of cleanup procs (inverses) that can be unrolled on shutdown.
    module ConfigWiring
      class << self
        def wire(shell)
          config = shell.config
          return [] unless config.respond_to?(:on_change)

          cleanups = []

          cleanups << config.on_change("workspace") do |key, val, _old|
            wire_workspace_change(shell, key, val)
          end

          cleanups << config.on_change("context") do |key, val, _old|
            wire_context_change(shell, key, val)
          end

          cleanups << config.on_change("lsp") do |key, val, _old|
            wire_lsp_change(shell, key, val)
          end

          ["llm", "models", "model", "providers", "router"].each do |prefix|
            cleanups << config.on_change(prefix) do |_key, _val, _old|
              wire_llm_change(shell)
            end
          end

          cleanups << config.on_change("ui") do |_key, _val, _old|
            shell.refresh_ui! if shell.respond_to?(:refresh_ui!)
          end

          cleanups << config.on_change("network.allow") do |_key, val, _old|
            config.set("sandbox.allow_network", val, persist: false) if config.fetch("sandbox.allow_network", nil) != val
          end

          cleanups << config.on_change("sandbox.allow_network") do |_key, val, _old|
            config.set("network.allow", val, persist: false) if config.fetch("network.allow", nil) != val
          end

          cleanups
        end

        private

        def wire_workspace_change(shell, key, typed_val)
          case key
          when "workspace.additional_roots"
            return unless typed_val.is_a?(Array)

            exp_roots = typed_val.map { |r| File.expand_path(r.to_s, shell.buffer_manager&.root_dir || Dir.pwd) }
            current_roots = shell.buffer_manager&.additional_roots || []
            new_roots = exp_roots - current_roots
            removed_roots = current_roots - exp_roots

            new_roots.each { |r| shell.buffer_manager&.add_root(r) }
            removed_roots.each { |r| shell.buffer_manager&.remove_root(r) }

            if (new_roots.any? || removed_roots.any?) &&
               shell.config.fetch("workspace.auto_index_additional", true) && shell.context_index
              shell.context_index.additional_roots = shell.buffer_manager&.additional_roots
              shell.context_index.full_scan
              shell.warm_ast_graph(async: false) if shell.respond_to?(:warm_ast_graph)
            end
          when "workspace.allowed_external_dirs"
            return unless typed_val.is_a?(Array)

            exp_dirs = typed_val.map { |d| File.expand_path(d.to_s, shell.buffer_manager&.root_dir || Dir.pwd) }
            current_dirs = shell.buffer_manager&.allowed_external_dirs || []
            new_dirs = exp_dirs - current_dirs
            removed_dirs = current_dirs - exp_dirs

            new_dirs.each do |d|
              shell.buffer_manager.add_allowed_dir(d) if shell.buffer_manager.respond_to?(:add_allowed_dir)
              shell.sandbox_runner&.add_allowed_dir(d)
            end
            removed_dirs.each do |d|
              shell.buffer_manager.remove_allowed_dir(d) if shell.buffer_manager.respond_to?(:remove_allowed_dir)
              shell.sandbox_runner&.remove_allowed_dir(d)
            end
          when "workspace.allow_external_writes"
            shell.buffer_manager.allow_external_writes = typed_val if shell.buffer_manager.respond_to?(:allow_external_writes=)
          end
        end

        def wire_context_change(shell, key, _typed_val)
          return unless ["context.include", "context.exclude"].include?(key)
          return unless shell.context_index.respond_to?(:update_file_filters)

          inc = shell.config.fetch("context.include", [])
          exc = shell.config.fetch("context.exclude", [])
          shell.context_index.update_file_filters(includes: inc, excludes: exc)
          shell.warm_ast_graph(async: false) if shell.respond_to?(:warm_ast_graph)
        end

        def wire_lsp_change(shell, key, typed_val)
          shell.lsp_manager&.stop_all if key == "lsp.enabled" && typed_val == false
        end

        def wire_llm_change(shell)
          shell.llm_registry&.load_from_config(shell.config)
          shell.conversation_route_stamp = nil if shell.respond_to?(:conversation_route_stamp=)
          begin
            Commands::Agent.sync_default_provider(shell) if defined?(Commands::Agent)
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
