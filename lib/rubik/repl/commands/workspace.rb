# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      module Workspace
        extend Base

        def self.register(shell)
          register_workspace_command(shell)
          register_allow_command(shell)
          register_allow_cmd_command(shell)
          register_config_command(shell)
        end

        # Operator-only command allowlist gate (Plan: komut-allowlist).
        # audience defaults to :human in Shell#register_command, so the agent
        # can never invoke this via exec_repl_command (fail-closed).
        private_class_method def self.register_allow_cmd_command(shell)
          shell.register_command("allow-cmd",
                                 description: "Operator-only command allowlist: add|list|remove token-prefix entries " \
                                              '(e.g. add "node .gitnexus/run.cjs" --project)') do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "list"

            handle_add = lambda do |tokens_to_add|
              entry_tokens = tokens_to_add.reject { |a| a == "--force" }
              entry = entry_tokens.join(" ").strip
              if entry.empty?
                shell.output.puts 'Usage: !allow-cmd add "<command prefix>" [--project|--global] [--force]'
                return
              end

              tokens = entry.split(/\s+/)
              broad = begin
                base = Rubik::Security::Classifier.classify(tokens.first)
                base.classification == :dangerous && tokens.size == 1
              rescue StandardError
                false
              end

              # Fail-closed against unbounded execution: a broad, single-token
              # dangerous entry (e.g. "node", "python", "bash") grants
              # command execution for EVERY invocation of that binary, so
              # `node` → `node -e 'malicious()'` RCE. Such broad tokens are
              # blocked with or without --force — the operator should use a
              # narrow prefix (e.g. "node .gitnexus/run.cjs").
              if broad
                shell.output.puts "Blocked: '#{entry}' is a broad, single-token dangerous command. Even with --force it grants " \
                                  "unbounded command execution (e.g. `#{tokens.first} -e 'malicious(...)'` RCE). " \
                                  "Use a narrow prefix instead (e.g. \"#{tokens.first} <script>\")."
                return
              end

              # The catastrophic destructive-pattern fallback always runs:
              # a dangerous multi-token entry may never add `rm -rf /`-style
              # chains to the allowlist, with or without --force.
              catastrophic = false
              begin
                shell.guard.verify_command_fallback_regex!(entry)
              rescue Rubik::Security::BlockedWriteError => e
                shell.output.puts "Blocked: '#{entry}' matches a catastrophic destructive pattern and cannot be allowlisted: #{e.message}"
                catastrophic = true
              end
              return if catastrophic

              current = Array(shell.config.fetch("security.command_allowlist", [])).dup
              if current.include?(entry)
                shell.output.puts "[Rubik::AllowCmd] '#{entry}' is already allowlisted."
                return
              end
              current << entry
              shell.config.set("security.command_allowlist", current, persist: scope)
              shell.guard&.log_audit("allowlist_add", command: entry, scope: scope)
              shell.output.puts "[Rubik::AllowCmd] Added command prefix: #{entry} [#{Base.scope_label(scope)}]."
            end

            case sub
            when "list", "status"
              entries = Array(shell.config.fetch("security.command_allowlist", []))
              shell.output.puts "=== Allowed Command Prefixes (operator allowlist) ==="
              if entries.empty?
                shell.output.puts "  (No command prefixes allowlisted — unknown/dangerous commands stay blocked)"
              else
                entries.each_with_index { |e, idx| shell.output.puts "  • [#{idx + 1}] #{e}" }
              end
            when "add"
              handle_add.call(clean_args[1..])
            when "remove", "rm", "delete"
              entry = clean_args[1..].join(" ").strip
              if entry.empty?
                shell.output.puts "Usage: !allow-cmd remove \"<command prefix>\" [--project|--global]"
                next
              end

              current = Array(shell.config.fetch("security.command_allowlist", [])).dup
              unless current.include?(entry)
                shell.output.puts "[Rubik::AllowCmd] '#{entry}' is not in the allowlist."
                next
              end
              current.delete(entry)
              shell.config.set("security.command_allowlist", current, persist: scope)
              shell.guard&.log_audit("allowlist_remove", command: entry, scope: scope)
              shell.output.puts "[Rubik::AllowCmd] Removed command prefix: #{entry} [#{Base.scope_label(scope)}]."
            when "help", "-h", "--help"
              shell.output.puts "Usage: !allow-cmd <add \"<prefix>\" [--force]|list|remove \"<prefix>\"> [--project|--global]"
            else
              handle_add.call(clean_args)
            end
          end
        end

        private_class_method def self.register_workspace_command(shell)
          workspace_handler = lambda do |args, _ctx|
            scope, clean_args = Base.parse_scope(args)
            is_rw = clean_args.include?("--rw") || clean_args.include?("-w")
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            clean_args = clean_args.reject { |a| ["--rw", "-w", "--ro", "-r"].include?(a) }
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
                  mode_str = glob_rw || rw_set.include?(r) ? "Read-Write" : "Read-Only"
                  shell.output.puts "  • [EXTRA #{idx + 1}] #{r} (#{mode_str})"
                end
              end

              shell.output.puts "=== Allowed External Dirs (Zero-AST) ==="
              if allowed_ext.empty?
                shell.output.puts "  (No allowed external directories configured)"
              else
                allowed_ext.each_with_index do |d, idx|
                  mode_str = glob_rw || rw_allowed_set.include?(d) ? "Read-Write" : "Read-Only"
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

          shell.register_command("workspace", description: "Manage multiple workspace roots (list|add <path> [--rw]|allow <path>|remove <path>)",
                                 &workspace_handler)
          shell.register_command("roots", description: "Alias for !workspace", &workspace_handler)
        end

        private_class_method def self.register_allow_command(shell)
          allow_handler = lambda do |args, _ctx, invoked_as: :allow_dir|
            scope, clean_args = Base.parse_scope(args)
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            clean_args.include?("--rw") || clean_args.include?("-w")
            clean_args = clean_args.reject { |a| ["--rw", "-w", "--ro", "-r"].include?(a) }

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
                  mode_str = glob_rw || rw_set.include?(d) ? "Read-Write" : "Read-Only"
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
                cmd_name = invoked_as == :allow ? "allow" : "allow-dir"
                shell.output.puts "Usage: !#{cmd_name} <path> [--rw|--ro] | !#{cmd_name} <list|remove <path>> [--project|--global]"
              end
            end
          end

          # Plan (komut-allowlist): `!allow-dir` is the primary command name;
          # `!allow` survives as a one-line deprecation wrapper around the same
          # handler (no silent breakage — Plan 48 muscle memory keeps working).
          shell.register_command("allow-dir",
                                 description: "Allow external directory for Buffer I/O and Sandbox without AST indexing " \
                                              "(!allow-dir <path> [--rw|--ro]|list|remove)", &allow_handler)
          deprecated_allow_wrapper = lambda do |args, _ctx|
            shell.output.puts "[Deprecation] '!allow' is an alias — use '!allow-dir' (folders) / '!allow-cmd' (commands)."
            allow_handler.call(args, invoked_as: :allow)
          end
          shell.register_command("allow", description: "Deprecated alias for !allow-dir", &deprecated_allow_wrapper)
        end

        private_class_method def self.register_config_command(shell)
          shell.register_command("config", description: "Get, set, or view runtime configuration (set|get|list|path)", audience: :both) do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub.nil? || sub.empty?
              shell.output.puts "Usage: !config <get <key> | set <key> <val> | list [filter] | path> [--project|--global]"
            elsif ["path", "paths"].include?(sub)
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
              elsif shell.agent_caller && key.start_with?("security.", "sandbox.")
                # Paket D fail-closed: the agent cannot grant itself command
                # allowlist entries or toggle sandbox enforcement.
                shell.output.puts "Security Error: keys under 'security.*' and 'sandbox.*' are operator-only " \
                                  "(mutated via !allow-cmd / !allow-dir as the human operator)."
              else
                shell.config.set(key, val, persist: scope)
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
                shell.output.puts "No configuration entries found#{" matching '#{filter}'" if filter}."
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
              else
                shell.output.puts "  • Ayar yapmak için : !config set #{clean_args[0]} <val>"
              end
              shell.output.puts "  • Değer okumak için: !config get #{clean_args[0]}"
            end
          end
        end
      end
    end
  end
end
