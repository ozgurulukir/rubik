# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../runtime"
require_relative "../../runtime/repair_probe"
require_relative "../../buffer/apply_contract"

module Rubik
  module Tools
    class ApplyBufferTool < BaseTool
      # maestro_blocked: false is DECLARED policy, not drift (TOOLS.md maestro
      # paragraph): apply_buffer is the manual-mode flush of a coder branch's
      # merge — the root orchestrator persists it directly, and with the gate
      # off the root edits-and-flushes itself.
      DECLARATION = Declaration.new(
        name: "apply_buffer", aliases: ["save_buffer", "commit_changes", "save"],
        description: "Persist all pending in-memory file buffer modifications to disk immediately (skips files with external conflicts unless force: true)",
        risk: :write, archetypes: [:coder], write_grant: true, maestro_blocked: false,
        params_schema: {
          type: "object",
          properties: {
            reason: { type: "string", description: "Optional explanation of why buffer is being applied (e.g. 'prior to running tests')" },
            force: { type: "boolean",
                     description: "If true, overwrites disk files even if modified externally by formatters (resolves [CONFLICT])" }
          }
        }
      )
      def initialize(buffer_manager = nil, shell = nil)
        super(DECLARATION)
        @buffer_manager = buffer_manager
        @shell = shell
      end

      def execute(args = {})
        return ToolOutput.error("Buffer manager is not connected.") unless @buffer_manager

        shell_config = @shell.respond_to?(:config) ? @shell.config : nil
        manager_config = @buffer_manager.respond_to?(:config) ? @buffer_manager.config : nil
        unless Rubik::Buffer::ApplyContract.model_can_apply?(shell_config: shell_config, manager_config: manager_config)
          return ToolOutput.error("Model buffer application is disabled by configuration " \
                                  "(buffer.model_can_apply: false). The human operator will review and apply changes.")
        end

        force = [true, "true"].include?(args["force"]) || [true, "true"].include?(args[:force]) ||
                [true, "true"].include?(args["overwrite"]) || [true, "true"].include?(args[:overwrite])
        policy = force ? "overwrite" : nil

        if @buffer_manager.dirty?
          applied = nil
          begin
            applied = @buffer_manager.apply!(policy: policy)
          rescue Rubik::Buffer::ApplyFailedError => e
            # Partial apply: files in e.applied ARE on disk — sync the model's
            # view for them and report the remainder honestly (issue #146).
            lines = Rubik::Buffer::ApplyContract.failure_lines(e, sync: ->(paths) { @shell&.sync_context_and_ast(paths) })
            return ToolOutput.error(lines.join("\n"))
          end
          conflicts = @buffer_manager.last_conflicts || []
          @shell&.sync_context_and_ast(applied) unless applied.empty?

          messages = []
          messages << "Successfully applied #{applied.size} modified file(s) to disk: #{applied.join(', ')}" unless applied.empty?
          conflicts.each do |c|
            messages << "[CONFLICT] #{c}: disk content changed since last read — skipped to prevent data loss.\n" \
                        "To force overwrite with your buffer changes, call: apply_buffer(force: true)\n" \
                        "Call read_file(path: \"#{c}\", reload: true) to inspect external changes or resolve."
          end

          if applied.empty? && !conflicts.empty?
            ToolOutput.error(messages.join("\n"))
          elsif applied.empty?
            # Inside the dirty? branch with zero applies and zero conflicts,
            # every buffered entry was discarded as an invalid path
            # (apply!'s garbage-skip) — the edits are NOT on disk, and citing
            # an earlier apply here would be a lie.
            "No unapplied buffer changes to write: the buffered entries were discarded as invalid paths and are NOT on disk. " \
              "Re-check the target paths and buffer them again."
          else
            messages.join("\n")
          end
        else
          Rubik::Buffer::ApplyContract.clean_buffer_message(@buffer_manager.last_applied, auto_apply_mode)
        end
      end

      private

      def auto_apply_mode
        return nil unless @shell.respond_to?(:config) && @shell.config.respond_to?(:fetch)

        @shell.config.fetch("buffer.auto_apply", "manual")
      end
    end

    class RepairRuntimeTool < BaseTool
      DECLARATION = Declaration.new(
        name: "repair_runtime_service", aliases: ["fix_service", "repair_lsp", "repair_runner", "repair_runtime"],
        description: "Diagnose, adapt, or synthesize a replacement command/adapter for a failing runtime component " \
                     "(LSP, test runner, linter, or shell command) with pre-flight verification in an isolated sub-context",
        risk: :execute, maestro_blocked: false, # runtime self-healing plane (TOOLS.md maestro policy)
        params_schema: {
          type: "object",
          properties: {
            target: {
              type: "string",
              enum: ["lsp", "test_runner", "linter", "command"],
              description: "Runtime component type to repair or adapt"
            },
            language_or_type: {
              type: "string",
              description: "Language or service identifier (e.g., 'ruby', 'python', 'rust', 'go', 'zig', 'c', 'bash')"
            },
            proposed_command: {
              oneOf: [{ type: "string" },
                      { type: "object", properties: { executable: { type: "string" },
                                                       args: { type: "array", items: { type: "string" } } },
                        required: ["executable", "args"], additionalProperties: false },
                      { type: "array", items: { type: "string" }, minItems: 1 }],
              description: "Replacement command: a legacy string or, for LSP, {executable, args} / argv array. Omit to probe automatically."
            },
            probe_args: {
              type: "array", items: { type: "string" },
              description: "Explicit non-mutating functional probe arguments appended to the exact proposed command; required for unknown executables"
            },
            auto_probe: {
              type: "boolean",
              description: "Whether to automatically probe system binaries and candidate commands (default: true)"
            }
          },
          required: ["target", "language_or_type"]
        }
      )
      def initialize(runtime_manager: nil, lsp_manager: nil, adapter_registry: nil, overlay_storage: nil, config: nil, root_dir: Dir.pwd,
                     guard: nil)
        super(DECLARATION)
        @runtime_manager = runtime_manager
        @lsp_manager = lsp_manager
        @adapter_registry = adapter_registry
        @overlay_storage = overlay_storage
        @config = config
        @root_dir = File.expand_path(root_dir)
        @guard = guard
      end

      def execute(args = {})
        target = (args["target"] || args[:target]).to_s.downcase.strip
        lang = (args["language_or_type"] || args[:language_or_type]).to_s.downcase.strip
        raw_command = args["proposed_command"] || args[:proposed_command]
        if raw_command.is_a?(Hash) || raw_command.is_a?(Array)
          return ToolOutput.error("Structured command argv is supported only for LSP repairs.") unless target == "lsp"

          proposed_cmd = raw_command
        else
          proposed_cmd = raw_command.to_s.strip
        end
        auto_probe = if args["auto_probe"].nil?
                       args[:auto_probe].nil? || args[:auto_probe]
                     else
                       args["auto_probe"]
                     end

        return ToolOutput.error("Target and language_or_type must be provided.") if target.empty? || lang.empty?

        # 1. Automatic Probing if proposed_cmd is not specified or auto_probe is requested
        if !command_provided?(proposed_cmd) && auto_probe
          candidate = case target
                      when "lsp"
                        Rubik::Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir)
                      when "test_runner"
                        Rubik::Runtime::Discovery.discover_test_runners(root_dir: @root_dir, lang: lang).first
                      when "linter"
                        Rubik::Runtime::Discovery.discover_formatters(root_dir: @root_dir, lang: lang).first
                      when "command"
                        Rubik::Runtime::Discovery.binary_available?(lang) ? lang : nil
                      end

          if candidate
            proposed_cmd = candidate
          else
            candidates = case target
                         when "lsp" then Rubik::Runtime::Discovery.lsp_candidates(lang)
                         when "test_runner" then Rubik::Runtime::Discovery.test_runner_candidates(lang, root_dir: @root_dir)
                         when "linter" then Rubik::Runtime::Discovery::FORMATTER_CANDIDATES[lang] || []
                         else []
                         end
            cand_str = candidates.empty? ? "none" : candidates.join(", ")
            return ToolOutput.error("Auto-probe failed to discover any installed candidate for #{target} (#{lang}). " \
                                    "Candidates checked: [#{cand_str}]. Please provide a specific `proposed_command`.")
          end
        end

        return ToolOutput.error("No command provided or discovered for #{target} (#{lang}).") unless command_provided?(proposed_cmd)

        # 2. Pre-flight Verification in Isolated Sub-Context (ctx.extend())
        root_ctx = @runtime_manager&.context || Rubik::Runtime::Context.new
        sub_ctx = root_ctx.extend

        verified = false
        error_diagnostic = nil

        begin
          verified, error_diagnostic = verify_binary(target, lang, proposed_cmd, sub_ctx, probe_args: args["probe_args"] || args[:probe_args])
        rescue StandardError => e
          error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
            cmd: proposed_cmd,
            exit_code: 1,
            stderr: "Exception during pre-flight sandbox check: #{e.message}"
          )
        ensure
          sub_ctx.dispose
        end

        return ToolOutput.error("Verification failed for #{target} (#{lang}):\n#{error_diagnostic&.format_for_llm}") unless verified

        # Live changes belong to a disposable transaction. Successful project
        # persistence is an operator decision and outlives lifecycle cleanup.
        promotion_ctx = root_ctx.extend
        released = false
        @repair_scopes ||= {}
        cfg_key = { "lsp" => "lsp.servers", "test_runner" => "test.runners",
                    "linter" => "linter.commands" }[target]
        cfg_key = "#{cfg_key}.#{lang}" if cfg_key
        prev_cmd = @config&.fetch(cfg_key) if cfg_key
        service_key = "#{{ 'test_runner' => 'runner' }.fetch(target, target)}:#{lang}"
        previous_services = root_ctx.services
        phase = "Promotion"
        begin
          promotion_ctx.on_dispose do
            next if released

            @repair_scopes.delete([root_ctx, service_key]) if @repair_scopes[[root_ctx, service_key]].equal?(promotion_ctx)
            unless root_ctx.disposed?
              if previous_services.key?(service_key)
                restored = target == "lsp" ? @lsp_manager&.clients&.[](lang) : nil
                root_ctx.provide(service_key, restored || previous_services[service_key])
              else
                root_ctx.unprovide(service_key)
              end
            end
          end
          if cfg_key && @config
            promotion_ctx.on_dispose do
              next if released

              prev_cmd.nil? ? @config.delete(cfg_key) : @config.set(cfg_key, prev_cmd)
            end
            @config.set(cfg_key, proposed_cmd)
          end

          case target
          when "lsp"
            raise "LSP manager and config are required for live activation" unless @lsp_manager && @config

            had_client = !@lsp_manager.clients[lang].nil?
            # The manager owns its client table. Restore the old configured
            # client on rollback; probe clients never enter that table.
            promotion_ctx.on_dispose do
              next if released

              @lsp_manager.stop_client(lang)
              prev_cmd.nil? ? @config.delete(cfg_key) : @config.set(cfg_key, prev_cmd)
              if had_client && !root_ctx.disposed?
                restored = @lsp_manager.start_client(lang)
                raise "Previous LSP client could not be restarted: #{restored}" unless restored[:ok]
              end
            end
            @lsp_manager.stop_client(lang)
            start_res = @lsp_manager.start_client(lang)
            raise "Failed to start LSP server: #{start_res}" unless start_res.is_a?(Hash) && start_res[:ok]

            service = @lsp_manager.clients[lang]
            raise "LSP manager reported success without an active client" unless service
          when "test_runner", "linter"
            if @adapter_registry
              adapter = @adapter_registry.get(lang)
              if adapter
                field = target == "test_runner" ? :custom_test_cmd : :custom_format_cmd
                old_value = adapter.public_send(field)
                old_config = adapter.config
                promotion_ctx.on_dispose do
                  next if released

                  adapter.public_send("#{field}=", old_value)
                  adapter.config = old_config
                end
                adapter.config ||= @config
                adapter.public_send("#{field}=", proposed_cmd)
              else
                require_relative "../../adapter/generic" unless defined?(Rubik::Adapter::GenericAdapter)
                options = target == "test_runner" ? { test_cmd: proposed_cmd } : { format_cmd: proposed_cmd }
                adapter = Rubik::Adapter::GenericAdapter.new(lang, **options, guard: @guard)
                adapter.config = @config
                promotion_ctx.on_dispose do
                  @adapter_registry.unregister(lang) if !released && @adapter_registry.get(lang).equal?(adapter)
                end
                @adapter_registry.register(lang, adapter)
              end
            end
            service = proposed_cmd
          when "command"
            service = proposed_cmd
          end

          root_ctx.provide(service_key, service)
          phase = "Persistence"
          persist_res = @config.set(cfg_key, proposed_cmd, persist: :project) if cfg_key && @config
          raise persist_res[:error].to_s if persist_res.is_a?(Hash) && !persist_res[:ok]
        rescue StandardError => e
          promotion_ctx.dispose
          rollback_errors = promotion_ctx.last_dispose_errors
          detail = rollback_errors.empty? ? "previous session state restored" : "rollback incomplete: #{rollback_errors}"
          return ToolOutput.error("#{phase} failed for #{target} (#{lang}): #{e.message}; #{detail}")
        end

        # Keep one lifetime inverse per repaired key, preserving the original
        # baseline across repeated repairs without retaining every transaction.
        scope_key = [root_ctx, service_key]
        if @repair_scopes.key?(scope_key)
          released = true
          promotion_ctx.dispose
        else
          @repair_scopes[scope_key] = promotion_ctx
        end

        if @config.nil? && ["lsp", "test_runner", "linter"].include?(target)
          return "⚠️ Promoted '#{display_command(proposed_cmd)}' for #{target} (#{lang}) — no config is attached, " \
                 "so the command is active for this session only and was not saved."
        end

        "✨ Successfully verified and promoted runtime service for #{target} (#{lang}): '#{display_command(proposed_cmd)}'. " \
          "Service is now active in the live context."
      end

      private

      def verify_binary(target, lang, proposed_cmd, sub_ctx, probe_args: nil)
        Rubik::Runtime::RepairProbe.new(root_dir: @root_dir).verify(target, lang, proposed_cmd, sub_ctx, probe_args: probe_args)
      end

      def command_provided?(command)
        if command.is_a?(String)
          !command.strip.empty?
        elsif command.is_a?(Hash) || command.is_a?(Array)
          !Rubik::LSP::ServerCommand.argv(command).empty?
        else
          false
        end
      rescue ArgumentError
        false
      end

      def display_command(command)
        command.is_a?(Hash) || command.is_a?(Array) ? Rubik::LSP::ServerCommand.display(command) : command.to_s
      end
    end

    class FinishTool < BaseTool
      DECLARATION = Declaration.new(
        name: "finish", aliases: ["complete", "done", "task_complete", "exit"],
        description: "Signal task completion with final message. Before finishing, re-verify headline claims " \
                     "(file lists, counts, command outcomes) against your raw command output — context " \
                     "compaction can blur report details, and the final report must match observed evidence.",
        risk: :execute, maestro_blocked: false, # the completion signal — handled before the gate; must stay direct
        params_schema: { type: "object",
                         properties: { message: { type: "string",
                                                  description: "Final summary message for the user describing what was accomplished (optional)" } } }
      )

      def initialize
        super(DECLARATION)
      end

      def execute(args = {})
        args["message"] || args[:message] || "Task finished"
      end
    end
  end
end
