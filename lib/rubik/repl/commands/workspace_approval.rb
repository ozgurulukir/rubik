# frozen_string_literal: true

require_relative "../../storage/layout"

module Rubik
  module REPL
    module Commands
      # Value object resolving one workspace/directory approval request:
      # (path, read-write mode, persistence scope, trust). All collaborators
      # (config, buffer manager, sandbox runner, security guard, output
      # stream) are injected explicitly — no ambient globals (AGENTS.md §5).
      #
      # The REPL command handlers stay thin adapters: they parse the raw
      # argv into these attributes, print usage lines, and delegate the
      # trust check, the runtime mutation and the config persistence here.
      # Every message spelling is pinned to what the handlers used to emit.
      class WorkspaceApproval
        attr_reader :path, :rw, :scope

        def initialize(path:, read_write:, scope:, config:, buffer_manager:, out:, guard:, sandbox_runner: nil,
                       index_sync: nil, effective_root: nil)
          @path = path
          @rw = read_write
          @scope = scope
          @config = config
          @buffer_manager = buffer_manager
          @out = out
          @guard = guard
          @sandbox_runner = sandbox_runner
          @index_sync = index_sync
          @effective_root = effective_root
        end

        # Trust resolution (fail-closed): a dangerous system root is refused
        # with the pinned "Security Error:" line before any mutation runs.
        def trusted?
          @guard.verify_root_safety!(@path)
          true
        rescue Rubik::Security::BlockedWriteError => e
          @out.puts "Security Error: #{e.message}"
          false
        end

        # !workspace add <path> [--rw]: register an additional workspace root
        # on the buffer manager, optionally re-index coeffects, and persist.
        def add_root!
          expanded = @buffer_manager.add_root(@path, rw: @rw)

          sync_index_if_enabled!

          current_roots = Array(Rubik::Storage::Layout.config_get(@config, "workspace.additional_roots", [])).dup
          # Persist the expanded path so `~/x` and its absolute form cannot
          # both accumulate as separate entries (issue #689).
          current_roots << expanded unless current_roots.include?(expanded)
          res = @config.set("workspace.additional_roots", current_roots, persist: @scope)
          return if Base.report_persist_failure(@out, res, @scope)

          mode_str = @rw ? "Read-Write" : "Read-Only"
          @out.puts "[Rubik::Workspace] Added additional root: #{expanded} (Mode: #{mode_str}) " \
                    "[#{Base.scope_label(@scope)}]."
        end

        # !workspace allow / !allow-dir add <path> [--rw|--ro]: allow an
        # external directory for Buffer I/O and Sandbox (Zero-AST: no index
        # sync) and persist.
        def allow_dir!
          expanded = @buffer_manager.add_allowed_dir(@path, rw: @rw)
          @sandbox_runner&.add_allowed_dir(@path)

          current_dirs = Array(Rubik::Storage::Layout.config_get(@config, "workspace.allowed_external_dirs", [])).dup
          current_dirs << expanded unless current_dirs.include?(expanded)
          res = @config.set("workspace.allowed_external_dirs", current_dirs, persist: @scope)
          return if Base.report_persist_failure(@out, res, @scope)

          rw_dirs = Array(Rubik::Storage::Layout.config_get(@config, "workspace.rw_allowed_dirs", [])).dup
          if @rw
            rw_dirs << expanded unless rw_dirs.include?(expanded)
          else
            rw_dirs.reject! { |d| File.expand_path(d.to_s, @effective_root) == expanded }
          end
          rw_res = @config.set("workspace.rw_allowed_dirs", rw_dirs, persist: @scope)
          return if Base.report_persist_failure(@out, rw_res, @scope)

          mode_str = @rw ? "Read-Write" : "Read-Only"
          @out.puts "[Rubik::Allow] Added allowed external directory: #{expanded} (Mode: #{mode_str}) " \
                    "[#{Base.scope_label(@scope)}]."
        end

        # !workspace remove <path>: unregister an additional root, re-index,
        # and prune persisted entries (matched by resolved path or raw arg).
        def remove_root!
          current_roots = Array(Rubik::Storage::Layout.config_get(@config, "workspace.additional_roots", [])).dup
          expanded = File.expand_path(@path.to_s, @effective_root)
          unless current_roots.any? { |r| File.expand_path(r.to_s, @effective_root) == expanded || r == @path }
            @out.puts "[Rubik::Workspace] '#{@path}' is not a configured additional root."
            return
          end

          expanded = @buffer_manager.remove_root(@path)

          sync_index_if_enabled!

          current_roots.reject! { |r| File.expand_path(r, @effective_root) == expanded || r == @path }
          res = @config.set("workspace.additional_roots", current_roots, persist: @scope)
          return if Base.report_persist_failure(@out, res, @scope)

          @out.puts "[Rubik::Workspace] Removed additional root: #{expanded} [#{Base.scope_label(@scope)}]."
        end

        # !allow-dir remove <path>: retract an allowed external directory
        # from Buffer and Sandbox, then prune persisted entries.
        def remove_allowed_dir!
          current_dirs = Array(Rubik::Storage::Layout.config_get(@config, "workspace.allowed_external_dirs", [])).dup
          expanded = File.expand_path(@path.to_s, @effective_root)
          unless current_dirs.any? { |d| File.expand_path(d.to_s, @effective_root) == expanded || d == @path }
            @out.puts "[Rubik::Allow] '#{@path}' is not a configured allowed external directory."
            return
          end

          expanded = @buffer_manager&.remove_allowed_dir(@path)
          @sandbox_runner&.remove_allowed_dir(@path)

          current_dirs.reject! { |d| File.expand_path(d.to_s, @effective_root) == expanded || d == @path }
          res = @config.set("workspace.allowed_external_dirs", current_dirs, persist: @scope)
          return if Base.report_persist_failure(@out, res, @scope)

          rw_dirs = Array(Rubik::Storage::Layout.config_get(@config, "workspace.rw_allowed_dirs", [])).dup
          rw_dirs.reject! { |d| File.expand_path(d.to_s, @effective_root) == expanded }
          rw_res = @config.set("workspace.rw_allowed_dirs", rw_dirs, persist: @scope)
          return if Base.report_persist_failure(@out, rw_res, @scope)

          @out.puts "[Rubik::Allow] Removed allowed external directory: #{expanded} [#{Base.scope_label(@scope)}]."
        end

        private

        # Sync context index & AST coeffects when auto-indexing is on
        # (workspace.auto_index_additional, default true).
        def sync_index_if_enabled!
          auto_idx = Rubik::Storage::Layout.config_get(@config, "workspace.auto_index_additional", true)
          @index_sync&.call if auto_idx
        end
      end

      # Value object for one operator command-prefix allowlist mutation
      # (!allow-cmd add|remove). Wraps the fail-closed broad-token RCE gate,
      # the catastrophic-pattern veto, duplicate handling and persistence
      # with the exact messages the inline handlers used to emit.
      class CommandPrefixApproval
        def initialize(config:, out:, guard:, classifier: Rubik::Security::Classifier)
          @config = config
          @out = out
          @guard = guard
          @classifier = classifier
        end

        def add(tokens_to_add, scope)
          entry_tokens = tokens_to_add.reject { |a| a == "--force" }
          entry = entry_tokens.join(" ").strip
          if entry.empty?
            @out.puts 'Usage: !allow-cmd add "<command prefix>" [--project|--global] [--force]'
            return
          end

          return if broad_token_blocked?(entry)

          return if catastrophic_pattern_blocked?(entry)

          current = Array(Rubik::Storage::Layout.config_get(@config, "security.command_allowlist", [])).dup
          if current.include?(entry)
            @out.puts "[Rubik::AllowCmd] '#{entry}' is already allowlisted."
            return
          end
          current << entry
          res = @config.set("security.command_allowlist", current, persist: scope)
          @guard&.log_audit("allowlist_add", command: entry, scope: scope)
          return if Base.report_persist_failure(@out, res, scope)

          @out.puts "[Rubik::AllowCmd] Added command prefix: #{entry} [#{Base.scope_label(scope)}]."
        end

        # Legacy shorthand (`!allow-cmd node`) still gets the same security
        # refusal; anything not refused is a typo, not an implicit `add`.
        def blocked_shorthand?(tokens)
          entry = tokens.reject { |token| token == "--force" }.join(" ").strip
          broad_token_blocked?(entry) || catastrophic_pattern_blocked?(entry)
        end

        def remove(entry, scope)
          current = Array(Rubik::Storage::Layout.config_get(@config, "security.command_allowlist", [])).dup
          unless current.include?(entry)
            @out.puts "[Rubik::AllowCmd] '#{entry}' is not in the allowlist."
            return
          end
          current.delete(entry)
          res = @config.set("security.command_allowlist", current, persist: scope)
          @guard&.log_audit("allowlist_remove", command: entry, scope: scope)
          return if Base.report_persist_failure(@out, res, scope)

          @out.puts "[Rubik::AllowCmd] Removed command prefix: #{entry} [#{Base.scope_label(scope)}]."
        end

        private

        # Fail closed (G3 triage, Priority-1 site): a classifier crash must
        # not silently skip the broad-token RCE check — treat the token as
        # broad and let the operator pass a narrow prefix.
        def broad_token_blocked?(entry)
          tokens = entry.split(/\s+/)
          broad = begin
            base = @classifier.classify(tokens.first)
            base.classification == :dangerous && tokens.size == 1
          rescue StandardError => e
            Rubik::Log.warn(:security, "classifier failed for '#{tokens.first}' (#{e.class}: #{e.message}); treating as broad")
            true
          end

          # Fail-closed against unbounded execution: a broad, single-token
          # dangerous entry (e.g. "node", "python", "bash") grants command
          # execution for EVERY invocation of that binary, so `node` →
          # `node -e 'malicious()'` RCE. Such broad tokens are blocked with
          # or without --force — the operator should use a narrow prefix.
          return false unless broad

          @out.puts "Blocked: '#{entry}' is a broad, single-token dangerous command. Even with --force it grants " \
                    "unbounded command execution (e.g. `#{tokens.first} -e 'malicious(...)'` RCE). " \
                    "Use a narrow prefix instead (e.g. \"#{tokens.first} <script>\")."
          true
        end

        # The catastrophic destructive-pattern fallback always runs: a
        # dangerous multi-token entry may never add `rm -rf /`-style chains
        # to the allowlist, with or without --force.
        def catastrophic_pattern_blocked?(entry)
          @guard.verify_command_fallback_regex!(entry)
          false
        rescue Rubik::Security::BlockedWriteError => e
          @out.puts "Blocked: '#{entry}' matches a catastrophic destructive pattern and cannot be allowlisted: #{e.message}"
          true
        end
      end
    end
  end
end
