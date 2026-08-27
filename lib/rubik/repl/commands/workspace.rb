# frozen_string_literal: true

require_relative "base"
require "set"

module Rubik
  module REPL
    module Commands
      module Workspace
        extend Base

        def self.register(shell)
          register_workspace_command(shell)
          register_allow_command(shell)
          register_config_command(shell)
        end

        private_class_method def self.register_workspace_command(shell)
          workspace_handler = lambda do |args|
            scope, clean_args = Base.parse_scope(args)
            is_rw = clean_args.include?("--rw") || clean_args.include?("-w")
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            clean_args = clean_args.reject { |a| %w[--rw -w --ro -r].include?(a) }
            sub = clean_args.first&.downcase || "list"

            effective_root = shell.buffer_manager&.root_dir || Dir.pwd

            case sub
            when "list", "status"
              extra = shell.buffer_manager&.additional_roots || []
              rw_set = shell.buffer_manager&.rw_roots || Set.new
              allowed_ext = shell.buffer_manager&.allowed_external_dirs || []
              rw_allowed_set = shell.buffer_manager&.rw_allowed_dirs || Set.new
              glob_rw = shell.buffer_manager&.allow_external_writes || false
              auto_idx = shell.config.fetch("workspace.auto_index_additional", true)

              shell.output.puts "=== Configured Workspace Roots ==="
              shell.output.puts "  • [PRIMARY] #{effective_root} (Read-Write)"
              if extra.empty?
                shell.output.puts "  (No additional workspace roots configured)"
              else
                extra.each_with_index do |r, idx|
                  mode_str = (glob_rw || rw_set.include?(r)) ? "Read-Write" : "Read-Only"
                  shell.output.puts "  • [EXTRA #{idx + 1}] #{r} (#{mode_str})"
                end
              end

              shell.output.puts "=== Allowed External Dirs (Zero-AST) ==="
              if allowed_ext.empty?
                shell.output.puts "  (No allowed external directories configured)"
              else
                allowed_ext.each_with_index do |d, idx|
                  mode_str = (glob_rw || rw_allowed_set.include?(d)) ? "Read-Write" : "Read-Only"
                  shell.output.puts "  • [ALLOWED #{idx + 1}] #{d} (#{mode_str})"
                end
              end

              shell.output.puts "External Writes Allowed Globally : #{glob_rw}"
              shell.output.puts "Auto-Index Additional Roots      : #{auto_idx}"
            when "allow"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !workspace allow <path> [--rw|--ro] [--project|--global]"
              else
                begin
                  shell.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  shell.output.puts "Security Error: #{e.message}"
                  next
                end

                mode_rw = !is_ro
                expanded = shell.buffer_manager.add_allowed_dir(target_path, rw: mode_rw)
                shell.sandbox_runner&.add_allowed_dir(target_path)

                current_dirs = Array(shell.config.fetch("workspace.allowed_external_dirs", [])).dup
                current_dirs << target_path unless current_dirs.include?(target_path)
                shell.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)

                mode_str = mode_rw ? "Read-Write" : "Read-Only"
                shell.output.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              end
            when "add"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !workspace add <path> [--rw] [--project|--global]"
              else
                begin
                  shell.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  shell.output.puts "Security Error: #{e.message}"
                  next
                end

                expanded = shell.buffer_manager.add_root(target_path, rw: is_rw)

                # Sync context index & AST coeffects
                if shell.config.fetch("workspace.auto_index_additional", true)
                  Rubik::Runtime::IndexService.sync_roots(
                    shell.runtime_manager,
                    shell.context_index,
                    additional_roots: shell.buffer_manager.additional_roots,
                    ast_graph: shell.ast_graph,
                    cache_store: shell.cache_store
                  )
                  shell.warm_ast_graph(async: false)
                end

                # Persist to config
                current_roots = Array(shell.config.fetch("workspace.additional_roots", [])).dup
                current_roots << target_path unless current_roots.include?(target_path)
                shell.config.set("workspace.additional_roots", current_roots, persist: scope)

                mode_str = is_rw ? "Read-Write" : "Read-Only"
                shell.output.puts "[Rubik::Workspace] Added additional root: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              end
            when "remove", "rm", "delete"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !workspace remove <path> [--project|--global]"
              else
                expanded = shell.buffer_manager.remove_root(target_path)

                # Sync context index & AST coeffects
                if shell.config.fetch("workspace.auto_index_additional", true)
                  Rubik::Runtime::IndexService.sync_roots(
                    shell.runtime_manager,
                    shell.context_index,
                    additional_roots: shell.buffer_manager.additional_roots,
                    ast_graph: shell.ast_graph,
                    cache_store: shell.cache_store
                  )
                  shell.warm_ast_graph(async: false)
                end

                # Persist to config
                current_roots = Array(shell.config.fetch("workspace.additional_roots", [])).dup
                current_roots.reject! { |r| File.expand_path(r, effective_root) == expanded || r == target_path }
                shell.config.set("workspace.additional_roots", current_roots, persist: scope)

                shell.output.puts "[Rubik::Workspace] Removed additional root: #{expanded} [#{Base.scope_label(scope)}]."
              end
            else
              shell.output.puts "Usage: !workspace <list | add <path> [--rw] | remove <path>> [--project|--global]"
            end
          end

          shell.register_command("workspace", description: "Manage multiple workspace roots (list|add <path> [--rw]|allow <path>|remove <path>)", &workspace_handler)
          shell.register_command("roots", description: "Alias for !workspace", &workspace_handler)
        end

        private_class_method def self.register_allow_command(shell)
          allow_handler = lambda do |args|
            scope, clean_args = Base.parse_scope(args)
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            is_rw = clean_args.include?("--rw") || clean_args.include?("-w")
            clean_args = clean_args.reject { |a| %w[--rw -w --ro -r].include?(a) }

            mode_rw = !is_ro
            sub = clean_args.first&.downcase || "list"
            effective_root = shell.buffer_manager&.root_dir || Dir.pwd

            case sub
            when "list", "status"
              allowed = shell.buffer_manager&.allowed_external_dirs || []
              rw_set = shell.buffer_manager&.rw_allowed_dirs || Set.new
              glob_rw = shell.buffer_manager&.allow_external_writes || false

              shell.output.puts "=== Allowed External Directories (Zero-AST / Zero-Scanner) ==="
              if allowed.empty?
                shell.output.puts "  (No allowed external directories configured)"
              else
                allowed.each_with_index do |d, idx|
                  mode_str = (glob_rw || rw_set.include?(d)) ? "Read-Write" : "Read-Only"
                  shell.output.puts "  • [ALLOWED #{idx + 1}] #{d} (#{mode_str})"
                end
              end
            when "remove", "rm", "delete"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !allow remove <path> [--project|--global]"
              else
                expanded = shell.buffer_manager&.remove_allowed_dir(target_path)
                shell.sandbox_runner&.remove_allowed_dir(target_path)

                # Persist to config
                current_dirs = Array(shell.config.fetch("workspace.allowed_external_dirs", [])).dup
                current_dirs.reject! { |d| File.expand_path(d, effective_root) == expanded || d == target_path }
                shell.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)

                shell.output.puts "[Rubik::Allow] Removed allowed external directory: #{expanded} [#{Base.scope_label(scope)}]."
              end
            when "add"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !allow add <path> [--rw|--ro] [--project|--global]"
              else
                begin
                  shell.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  shell.output.puts "Security Error: #{e.message}"
                  next
                end

                expanded = shell.buffer_manager.add_allowed_dir(target_path, rw: mode_rw)
                shell.sandbox_runner&.add_allowed_dir(target_path)

                # Persist to config (Zero-AST / Zero-Scanner: No IndexService or AST warm)
                current_dirs = Array(shell.config.fetch("workspace.allowed_external_dirs", [])).dup
                current_dirs << target_path unless current_dirs.include?(target_path)
                shell.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)

                mode_str = mode_rw ? "Read-Write" : "Read-Only"
                shell.output.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              end
            else
              # First argument is target path directly
              target_path = clean_args.first
              if target_path && !target_path.empty?
                begin
                  shell.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  shell.output.puts "Security Error: #{e.message}"
                  next
                end

                expanded = shell.buffer_manager.add_allowed_dir(target_path, rw: mode_rw)
                shell.sandbox_runner&.add_allowed_dir(target_path)

                current_dirs = Array(shell.config.fetch("workspace.allowed_external_dirs", [])).dup
                current_dirs << target_path unless current_dirs.include?(target_path)
                shell.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)

                mode_str = mode_rw ? "Read-Write" : "Read-Only"
                shell.output.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              else
                shell.output.puts "Usage: !allow <path> [--rw|--ro] | !allow <list|remove <path>> [--project|--global]"
              end
            end
          end

          shell.register_command("allow", description: "Allow external directory for Buffer I/O and Sandbox without AST indexing (!allow <path> [--rw|--ro]|list|remove)", &allow_handler)
          shell.register_command("allow-dir", description: "Alias for !allow", &allow_handler)
        end

        private_class_method def self.register_config_command(shell)
          shell.register_command("config", description: "Get, set, or view runtime configuration (set|get|list|path)") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub.nil? || sub.empty?
              shell.output.puts "Usage: !config <get <key> | set <key> <val> | list [filter] | path> [--project|--global]"
            elsif sub == "path" || sub == "paths"
              shell.output.puts "Global Config  : #{shell.config.global_config_path} (exists: #{File.exist?(shell.config.global_config_path)})"
              shell.output.puts "Project Config : #{shell.config.project_config_path} (exists: #{File.exist?(shell.config.project_config_path)})"
            elsif sub == "get"
              key = clean_args[1]
              if key.nil? || key.empty?
                shell.output.puts "Usage: !config get <key>"
              else
                val = shell.config.fetch(key)
                if val.nil?
                  shell.output.puts "Config '#{key}' is not set or empty."
                else
                  shell.output.puts "#{key} = #{val}"
                end
              end
            elsif sub == "set"
              key = clean_args[1]
              val = clean_args[2..]&.join(" ")
              if key.nil? || key.empty? || val.nil? || val.empty?
                shell.output.puts "Usage: !config set <key> <val> [--project|--global]"
              else
                typed_val = shell.config.set(key, val, persist: scope)
                if key == "workspace.additional_roots" && typed_val.is_a?(Array)
                  typed_val.each { |r| shell.buffer_manager.add_root(r) }
                  if shell.config.fetch("workspace.auto_index_additional", true)
                    shell.context_index.additional_roots = shell.buffer_manager.additional_roots
                    shell.context_index.full_scan
                    shell.warm_ast_graph(async: false)
                  end
                elsif key == "workspace.allowed_external_dirs" && typed_val.is_a?(Array)
                  typed_val.each do |d|
                    shell.buffer_manager.add_allowed_dir(d)
                    shell.sandbox_runner&.add_allowed_dir(d)
                  end
                elsif key == "workspace.allow_external_writes"
                  shell.buffer_manager.allow_external_writes = typed_val
                elsif key == "lsp.enabled"
                  shell.lsp_manager&.stop_all if typed_val == false
                elsif key.start_with?("providers.") || key.start_with?("router.") || key.start_with?("context.")
                  shell.llm_registry&.load_from_config(shell.config)
                  Agent.sync_default_provider(shell) rescue nil
                elsif key.start_with?("ui.")
                  # Display layer settings rebuild live: theme, spinner and
                  # statusline react without restarting the REPL.
                  shell.refresh_ui!
                end
                shell.output.puts "Config '#{key}' updated to '#{val}' [#{Base.scope_label(scope)}]."
              end
            elsif sub == "list"
              filter = clean_args[1]&.downcase
              flattened = {}
              flatten_proc = lambda do |hash, prefix|
                hash.each do |k, v|
                  full_k = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
                  if v.is_a?(Hash)
                    flatten_proc.call(v, full_k)
                  else
                    flattened[full_k] = v
                  end
                end
              end
              flatten_proc.call(shell.config.data, "")

              matched = filter ? flattened.select { |k, _| k.downcase.include?(filter) } : flattened
              if matched.empty?
                shell.output.puts "No configuration entries found#{filter ? " matching '#{filter}'" : ''}."
              else
                shell.output.puts "=== Rubik Configuration (#{matched.size} entries) ==="
                matched.sort.each do |k, v|
                  shell.output.puts "  • #{k.ljust(35)} = #{v.inspect}"
                end
              end
            else
              # Smart guidance for verbless input
              shell.output.puts "[Rubik::Config] Geçersiz kullanım."
              if clean_args.size >= 2
                shell.output.puts "  • Ayar yapmak için : !config set #{clean_args[0]} #{clean_args[1]}"
                shell.output.puts "  • Değer okumak için: !config get #{clean_args[0]}"
              else
                shell.output.puts "  • Ayar yapmak için : !config set #{clean_args[0]} <val>"
                shell.output.puts "  • Değer okumak için: !config get #{clean_args[0]}"
              end
            end
          end
        end
      end
    end
  end
end