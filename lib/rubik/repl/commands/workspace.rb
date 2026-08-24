# frozen_string_literal: true

require_relative "base"
require "set"

module Rubik
  module REPL
    module Commands
      module Workspace
        extend Base

        def self.register(shell)
          workspace_handler = lambda do |args|
            scope, clean_args = Base.parse_scope(args)
            is_rw = clean_args.include?("--rw") || clean_args.include?("-w")
            clean_args = clean_args.reject { |a| %w[--rw -w].include?(a) }
            sub = clean_args.first&.downcase || "list"

            effective_root = shell.buffer_manager&.root_dir || Dir.pwd

            case sub
            when "list", "status"
              extra = shell.buffer_manager&.additional_roots || []
              rw_set = shell.buffer_manager&.rw_roots || Set.new
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
              shell.output.puts "External Writes Allowed Globally : #{glob_rw}"
              shell.output.puts "Auto-Index Additional Roots      : #{auto_idx}"
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

                # Sync context index
                if shell.config.fetch("workspace.auto_index_additional", true)
                  shell.context_index.additional_roots = shell.buffer_manager.additional_roots
                  shell.context_index.full_scan
                  shell.warm_ast_graph(async: false)
                end

                # Persist to config
                current_roots = Array(shell.config.fetch("workspace.additional_roots", [])).dup
                current_roots << target_path unless current_roots.include?(target_path)
                shell.config.set("workspace.additional_roots", current_roots, persist: scope)

                mode_str = is_rw ? "Read-Write" : "Read-Only"
                shell.output.puts "[Rubik::Workspace] Added additional root: #{expanded} (Mode: #{mode_str}) [Saved to #{scope} config]"
              end
            when "remove", "rm", "delete"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                shell.output.puts "Usage: !workspace remove <path> [--project|--global]"
              else
                expanded = shell.buffer_manager.remove_root(target_path)

                # Sync context index
                if shell.config.fetch("workspace.auto_index_additional", true)
                  shell.context_index.additional_roots = shell.buffer_manager.additional_roots
                  shell.context_index.full_scan
                  shell.warm_ast_graph(async: false)
                end

                # Persist to config
                current_roots = Array(shell.config.fetch("workspace.additional_roots", [])).dup
                current_roots.reject! { |r| File.expand_path(r, effective_root) == expanded || r == target_path }
                shell.config.set("workspace.additional_roots", current_roots, persist: scope)

                shell.output.puts "[Rubik::Workspace] Removed additional root: #{expanded} [Saved to #{scope} config]"
              end
            else
              shell.output.puts "Usage: !workspace <list | add <path> [--rw] | remove <path>> [--project|--global]"
            end
          end

          shell.register_command("workspace", description: "Manage multiple workspace roots (list|add <path> [--rw]|remove <path>)", &workspace_handler)
          shell.register_command("roots", description: "Alias for !workspace", &workspace_handler)

          shell.register_command("config", description: "Get, set, or view runtime configuration paths") do |args|
            sub = args.first
            if sub == "get"
              key = args[1]
              shell.output.puts "#{key} = #{shell.config.fetch(key)}"
            elsif sub == "path" || sub == "paths"
              shell.output.puts "Global Config  : #{shell.config.global_config_path} (exists: #{File.exist?(shell.config.global_config_path)})"
              shell.output.puts "Project Config : #{shell.config.project_config_path} (exists: #{File.exist?(shell.config.project_config_path)})"
            elsif sub == "set"
              key = args[1]
              val = args[2]
              scope, _ = Base.parse_scope(args)
              typed_val = shell.config.set(key, val, persist: scope)
              if key == "workspace.additional_roots" && typed_val.is_a?(Array)
                typed_val.each { |r| shell.buffer_manager.add_root(r) }
                if shell.config.fetch("workspace.auto_index_additional", true)
                  shell.context_index.additional_roots = shell.buffer_manager.additional_roots
                  shell.context_index.full_scan
                  shell.warm_ast_graph(async: false)
                end
              elsif key == "workspace.allow_external_writes"
                shell.buffer_manager.allow_external_writes = typed_val
              end
              shell.output.puts "Config '#{key}' updated to '#{val}' [Saved to #{scope} config]"
            else
              shell.output.puts "Usage: !config <get <key> | set <key> <val> [--project|--global] | path>"
            end
          end
        end
      end
    end
  end
end
