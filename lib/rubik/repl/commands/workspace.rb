# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      module Workspace
        extend Base

        # Top-level command synopses: one constant per command, referenced by
        # both the spine registration (usage:) and the fallback branch that
        # prints it, so the two cannot drift.
        USAGE_WORKSPACE = "Usage: !workspace <list | add <path> [--rw] | remove <path>> [--project|--global]"
        USAGE_ALLOW = "Usage: !%<cmd>s <path> [--rw|--ro] | !%<cmd>s <list|remove <path>> [--project|--global]"
        USAGE_ALLOW_CMD = "Usage: !allow-cmd <add \"<prefix>\" [--force]|list|remove \"<prefix>\"> [--project|--global]"
        USAGE_CONFIG = "Usage: !config <get <key> | set <key> <val> | list [filter] | path> [--project|--global]"

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
                                              '(e.g. add "node .gitnexus/run.cjs" --project)',
                                 usage: USAGE_ALLOW_CMD) do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "list"

            case sub
            when "list", "status"
              handle_allow_cmd_list(ctx)
            when "add"
              handle_allow_cmd_add(ctx, clean_args[1..], scope)
            when "remove", "rm", "delete"
              handle_allow_cmd_remove(ctx, clean_args, scope)
            when "help", "-h", "--help"
              ctx.out.puts USAGE_ALLOW_CMD
            else
              handle_allow_cmd_add(ctx, clean_args, scope)
            end
          end
        end

        private_class_method def self.handle_allow_cmd_list(ctx)
          entries = Array(ctx.config.fetch("security.command_allowlist", []))
          ctx.out.puts "=== Allowed Command Prefixes (operator allowlist) ==="
          if entries.empty?
            ctx.out.puts "  (No command prefixes allowlisted — unknown/dangerous commands stay blocked)"
          else
            entries.each_with_index { |e, idx| ctx.out.puts "  • [#{idx + 1}] #{e}" }
          end
        end

        private_class_method def self.handle_allow_cmd_add(ctx, tokens_to_add, scope)
          entry_tokens = tokens_to_add.reject { |a| a == "--force" }
          entry = entry_tokens.join(" ").strip
          if entry.empty?
            ctx.out.puts 'Usage: !allow-cmd add "<command prefix>" [--project|--global] [--force]'
            return
          end

          tokens = entry.split(/\s+/)
          # Fail closed (G3 triage, Priority-1 site): a classifier crash
          # must not silently skip the broad-token RCE check — treat the
          # token as broad and let the operator pass a narrow prefix.
          broad = begin
            base = Rubik::Security::Classifier.classify(tokens.first)
            base.classification == :dangerous && tokens.size == 1
          rescue StandardError => e
            Rubik::Log.warn(:security, "classifier failed for '#{tokens.first}' (#{e.class}: #{e.message}); treating as broad")
            true
          end

          # Fail-closed against unbounded execution: a broad, single-token
          # dangerous entry (e.g. "node", "python", "bash") grants
          # command execution for EVERY invocation of that binary, so
          # `node` → `node -e 'malicious()'` RCE. Such broad tokens are
          # blocked with or without --force — the operator should use a
          # narrow prefix (e.g. "node .gitnexus/run.cjs").
          if broad
            ctx.out.puts "Blocked: '#{entry}' is a broad, single-token dangerous command. Even with --force it grants " \
                         "unbounded command execution (e.g. `#{tokens.first} -e 'malicious(...)'` RCE). " \
                         "Use a narrow prefix instead (e.g. \"#{tokens.first} <script>\")."
            return
          end

          # The catastrophic destructive-pattern fallback always runs:
          # a dangerous multi-token entry may never add `rm -rf /`-style
          # chains to the allowlist, with or without --force.
          catastrophic = false
          begin
            ctx.guard.verify_command_fallback_regex!(entry)
          rescue Rubik::Security::BlockedWriteError => e
            ctx.out.puts "Blocked: '#{entry}' matches a catastrophic destructive pattern and cannot be allowlisted: #{e.message}"
            catastrophic = true
          end
          return if catastrophic

          current = Array(ctx.config.fetch("security.command_allowlist", [])).dup
          if current.include?(entry)
            ctx.out.puts "[Rubik::AllowCmd] '#{entry}' is already allowlisted."
            return
          end
          current << entry
          res = ctx.config.set("security.command_allowlist", current, persist: scope)
          ctx.guard&.log_audit("allowlist_add", command: entry, scope: scope)
          return if Base.report_persist_failure(ctx, res, scope)

          ctx.out.puts "[Rubik::AllowCmd] Added command prefix: #{entry} [#{Base.scope_label(scope)}]."
        end

        private_class_method def self.handle_allow_cmd_remove(ctx, clean_args, scope)
          entry = clean_args[1..].join(" ").strip
          if entry.empty?
            ctx.out.puts "Usage: !allow-cmd remove \"<command prefix>\" [--project|--global]"
            return
          end

          current = Array(ctx.config.fetch("security.command_allowlist", [])).dup
          unless current.include?(entry)
            ctx.out.puts "[Rubik::AllowCmd] '#{entry}' is not in the allowlist."
            return
          end
          current.delete(entry)
          res = ctx.config.set("security.command_allowlist", current, persist: scope)
          ctx.guard&.log_audit("allowlist_remove", command: entry, scope: scope)
          return if Base.report_persist_failure(ctx, res, scope)

          ctx.out.puts "[Rubik::AllowCmd] Removed command prefix: #{entry} [#{Base.scope_label(scope)}]."
        end

        private_class_method def self.register_workspace_command(shell)
          workspace_handler = lambda do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            is_rw = clean_args.include?("--rw") || clean_args.include?("-w")
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            clean_args = clean_args.reject { |a| ["--rw", "-w", "--ro", "-r"].include?(a) }
            sub = clean_args.first&.downcase || "list"

            effective_root = ctx.buffer_manager&.root_dir || Dir.pwd

            case sub
            when "list", "status"
              extra = ctx.buffer_manager&.additional_roots || []
              rw_set = ctx.buffer_manager&.rw_roots || Set.new
              allowed_ext = ctx.buffer_manager&.allowed_external_dirs || []
              rw_allowed_set = ctx.buffer_manager&.rw_allowed_dirs || Set.new
              glob_rw = ctx.buffer_manager&.allow_external_writes || false
              auto_idx = ctx.config.fetch("workspace.auto_index_additional", true)

              ctx.out.puts "=== Configured Workspace Roots ==="
              ctx.out.puts "  • [PRIMARY] #{effective_root} (Read-Write)"
              if extra.empty?
                ctx.out.puts "  (No additional workspace roots configured)"
              else
                extra.each_with_index do |r, idx|
                  mode_str = glob_rw || rw_set.include?(r) ? "Read-Write" : "Read-Only"
                  ctx.out.puts "  • [EXTRA #{idx + 1}] #{r} (#{mode_str})"
                end
              end

              ctx.out.puts "=== Allowed External Dirs (Zero-AST) ==="
              if allowed_ext.empty?
                ctx.out.puts "  (No allowed external directories configured)"
              else
                allowed_ext.each_with_index do |d, idx|
                  mode_str = glob_rw || rw_allowed_set.include?(d) ? "Read-Write" : "Read-Only"
                  ctx.out.puts "  • [ALLOWED #{idx + 1}] #{d} (#{mode_str})"
                end
              end

              ctx.out.puts "External Writes Allowed Globally : #{glob_rw}"
              ctx.out.puts "Auto-Index Additional Roots      : #{auto_idx}"
            when "allow"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                ctx.out.puts "Usage: !workspace allow <path> [--rw|--ro] [--project|--global]"
              else
                begin
                  ctx.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  ctx.out.puts "Security Error: #{e.message}"
                  next
                end

                mode_rw = !is_ro
                expanded = ctx.buffer_manager.add_allowed_dir(target_path, rw: mode_rw)
                ctx.sandbox_runner&.add_allowed_dir(target_path)

                current_dirs = Array(ctx.config.fetch("workspace.allowed_external_dirs", [])).dup
                current_dirs << target_path unless current_dirs.include?(target_path)
                res = ctx.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                mode_str = mode_rw ? "Read-Write" : "Read-Only"
                ctx.out.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              end
            when "add"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                ctx.out.puts "Usage: !workspace add <path> [--rw] [--project|--global]"
              else
                begin
                  ctx.guard.verify_root_safety!(target_path)
                rescue Rubik::Security::BlockedWriteError => e
                  ctx.out.puts "Security Error: #{e.message}"
                  next
                end

                expanded = ctx.buffer_manager.add_root(target_path, rw: is_rw)

                # Sync context index & AST coeffects
                auto_idx = ctx.config.fetch("workspace.auto_index_additional", true)
                ctx.sync_workspace_index! if auto_idx

                # Persist to config
                current_roots = Array(ctx.config.fetch("workspace.additional_roots", [])).dup
                current_roots << target_path unless current_roots.include?(target_path)
                res = ctx.config.set("workspace.additional_roots", current_roots, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                mode_str = is_rw ? "Read-Write" : "Read-Only"
                ctx.out.puts "[Rubik::Workspace] Added additional root: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
              end
            when "remove", "rm", "delete"
              target_path = clean_args[1]
              if target_path.nil? || target_path.empty?
                ctx.out.puts "Usage: !workspace remove <path> [--project|--global]"
              else
                expanded = ctx.buffer_manager.remove_root(target_path)

                # Sync context index & AST coeffects
                auto_idx = ctx.config.fetch("workspace.auto_index_additional", true)
                ctx.sync_workspace_index! if auto_idx

                # Persist to config
                current_roots = Array(ctx.config.fetch("workspace.additional_roots", [])).dup
                current_roots.reject! { |r| File.expand_path(r, effective_root) == expanded || r == target_path }
                res = ctx.config.set("workspace.additional_roots", current_roots, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "[Rubik::Workspace] Removed additional root: #{expanded} [#{Base.scope_label(scope)}]."
              end
            else
              ctx.out.puts USAGE_WORKSPACE
            end
          end

          shell.register_command("workspace", description: "Manage multiple workspace roots (list|add <path> [--rw]|allow <path>|remove <path>)",
                                              usage: USAGE_WORKSPACE, &workspace_handler)
          shell.register_command("roots", description: "Alias for !workspace", usage: USAGE_WORKSPACE, &workspace_handler)
        end

        private_class_method def self.register_allow_command(shell)
          allow_handler = lambda do |args, ctx, invoked_as: :allow_dir|
            scope, clean_args = Base.parse_scope(args)
            is_ro = clean_args.include?("--ro") || clean_args.include?("-r")
            clean_args = clean_args.reject { |a| ["--rw", "-w", "--ro", "-r"].include?(a) }

            mode_rw = !is_ro
            sub = clean_args.first&.downcase || "list"
            effective_root = ctx.buffer_manager&.root_dir || Dir.pwd

            case sub
            when "list", "status"
              handle_allow_list(ctx)
            when "remove", "rm", "delete"
              handle_allow_remove(clean_args[1], ctx, scope, effective_root)
            when "add"
              handle_allow_add(clean_args[1], ctx, scope, mode_rw)
            else
              # First argument is target path directly
              target_path = clean_args.first
              if target_path && !target_path.empty?
                handle_allow_add(target_path, ctx, scope, mode_rw)
              else
                cmd_name = invoked_as == :allow ? "allow" : "allow-dir"
                ctx.out.puts format(USAGE_ALLOW, cmd: cmd_name)
              end
            end
          end

          # Plan (komut-allowlist): `!allow-dir` is the primary command name;
          # `!allow` survives as a one-line deprecation wrapper around the same
          # handler (no silent breakage — Plan 48 muscle memory keeps working).
          shell.register_command("allow-dir",
                                 description: "Allow external directory for Buffer I/O and Sandbox without AST indexing " \
                                              "(!allow-dir <path> [--rw|--ro]|list|remove)",
                                 usage: format(USAGE_ALLOW, cmd: "allow-dir"), &allow_handler)
          deprecated_allow_wrapper = lambda do |args, ctx|
            ctx.out.puts "[Deprecation] '!allow' is an alias — use '!allow-dir' (folders) / '!allow-cmd' (commands)."
            allow_handler.call(args, ctx, invoked_as: :allow)
          end
          shell.register_command("allow", description: "Deprecated alias for !allow-dir",
                                          usage: format(USAGE_ALLOW, cmd: "allow"), &deprecated_allow_wrapper)
        end

        private_class_method def self.handle_allow_list(ctx)
          allowed = ctx.buffer_manager&.allowed_external_dirs || []
          rw_set = ctx.buffer_manager&.rw_allowed_dirs || Set.new
          glob_rw = ctx.buffer_manager&.allow_external_writes || false

          ctx.out.puts "=== Allowed External Directories (Zero-AST / Zero-Scanner) ==="
          if allowed.empty?
            ctx.out.puts "  (No allowed external directories configured)"
          else
            allowed.each_with_index do |d, idx|
              mode_str = glob_rw || rw_set.include?(d) ? "Read-Write" : "Read-Only"
              ctx.out.puts "  • [ALLOWED #{idx + 1}] #{d} (#{mode_str})"
            end
          end
        end

        private_class_method def self.handle_allow_remove(target_path, ctx, scope, effective_root)
          if target_path.nil? || target_path.empty?
            ctx.out.puts "Usage: !allow remove <path> [--project|--global]"
            return
          end

          expanded = ctx.buffer_manager&.remove_allowed_dir(target_path)
          ctx.sandbox_runner&.remove_allowed_dir(target_path)

          # Persist to config
          current_dirs = Array(ctx.config.fetch("workspace.allowed_external_dirs", [])).dup
          current_dirs.reject! { |d| File.expand_path(d, effective_root) == expanded || d == target_path }
          res = ctx.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)
          return if Base.report_persist_failure(ctx, res, scope)

          ctx.out.puts "[Rubik::Allow] Removed allowed external directory: #{expanded} [#{Base.scope_label(scope)}]."
        end

        private_class_method def self.handle_allow_add(target_path, ctx, scope, mode_rw)
          if target_path.nil? || target_path.empty?
            ctx.out.puts "Usage: !allow add <path> [--rw|--ro] [--project|--global]"
            return
          end

          begin
            ctx.guard.verify_root_safety!(target_path)
          rescue Rubik::Security::BlockedWriteError => e
            ctx.out.puts "Security Error: #{e.message}"
            return
          end

          expanded = ctx.buffer_manager.add_allowed_dir(target_path, rw: mode_rw)
          ctx.sandbox_runner&.add_allowed_dir(target_path)

          # Persist to config (Zero-AST / Zero-Scanner: No IndexService or AST warm)
          current_dirs = Array(ctx.config.fetch("workspace.allowed_external_dirs", [])).dup
          current_dirs << target_path unless current_dirs.include?(target_path)
          res = ctx.config.set("workspace.allowed_external_dirs", current_dirs, persist: scope)
          return if Base.report_persist_failure(ctx, res, scope)

          mode_str = mode_rw ? "Read-Write" : "Read-Only"
          ctx.out.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) [#{Base.scope_label(scope)}]."
        end

        private_class_method def self.register_config_command(shell)
          shell.register_command("config", description: "Get, set, or view runtime configuration (set|get|list|path)",
                                           usage: USAGE_CONFIG, audience: :both) do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub.nil? || sub.empty?
              ctx.out.puts USAGE_CONFIG
            elsif ["path", "paths"].include?(sub)
              ctx.out.puts "Global Config  : #{ctx.config.global_config_path} (exists: #{File.exist?(ctx.config.global_config_path)})"
              ctx.out.puts "Project Config : #{ctx.config.project_config_path} (exists: #{File.exist?(ctx.config.project_config_path)})"
            elsif sub == "get"
              key = clean_args[1]
              if key.nil? || key.empty?
                ctx.out.puts "Usage: !config get <key>"
              else
                val = ctx.config.fetch(key)
                if val.nil?
                  ctx.out.puts "Config '#{key}' is not set or empty."
                else
                  ctx.out.puts "#{key} = #{val}"
                end
              end
            elsif sub == "set"
              key = clean_args[1]
              val = clean_args[2..]&.join(" ")
              if key.nil? || key.empty? || val.nil? || val.empty?
                ctx.out.puts "Usage: !config set <key> <val> [--project|--global]"
              elsif ctx.agent_caller && key.start_with?("security.", "sandbox.", "subagents.")
                # Paket D fail-closed: the agent cannot grant itself command
                # allowlist entries or toggle sandbox enforcement. subagents.*
                # da operatör-only: ajan kendi tasmasını (maestro_gate,
                # concurrency, reap grace) exec_repl_command ile çözemez —
                # kapı canlı config okur, self-unlock yolu bu yüzden kapalı.
                ctx.out.puts "Security Error: keys under 'security.*' and 'sandbox.*' are operator-only " \
                             "(mutated via !allow-cmd / !allow-dir as the human operator)."
              else
                res = ctx.config.set(key, val, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "Config '#{key}' updated to '#{val}' [#{Base.scope_label(scope)}]."
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
              flatten_proc.call(ctx.config.data, "")

              matched = filter ? flattened.select { |k, _| k.downcase.include?(filter) } : flattened
              if matched.empty?
                ctx.out.puts "No configuration entries found#{" matching '#{filter}'" if filter}."
              else
                ctx.out.puts "=== Rubik Configuration (#{matched.size} entries) ==="
                matched.sort.each do |k, v|
                  ctx.out.puts "  • #{k.ljust(35)} = #{v.inspect}"
                end
              end
            else
              # Smart guidance for verbless input
              ctx.out.puts "[Rubik::Config] Geçersiz kullanım."
              if clean_args.size >= 2
                ctx.out.puts "  • Ayar yapmak için : !config set #{clean_args[0]} #{clean_args[1]}"
              else
                ctx.out.puts "  • Ayar yapmak için : !config set #{clean_args[0]} <val>"
              end
              ctx.out.puts "  • Değer okumak için: !config get #{clean_args[0]}"
            end
          end
        end
      end
    end
  end
end
