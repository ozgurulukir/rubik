# frozen_string_literal: true

require_relative "../base"
require_relative "../../runtime"

module Rubik
  module Tools
    class ApplyBufferTool < BaseTool
      def initialize(buffer_manager = nil, shell = nil)
        super(
          name: "apply_buffer",
          aliases: ["save_buffer", "commit_changes", "save"],
          description: "Persist all pending in-memory file buffer modifications to disk immediately",
          risk: :write,
          params_schema: {
            type: "object",
            properties: {
              reason: { type: "string", description: "Optional explanation of why buffer is being applied (e.g. 'prior to running tests')" }
            }
          }
        )
        @buffer_manager = buffer_manager
        @shell = shell
      end

      def execute(_args = {})
        return "Buffer manager is not connected" unless @buffer_manager

        if @shell&.config && @shell.config.fetch("buffer.model_can_apply", true) == false
          return "Model buffer application is disabled by configuration (buffer.model_can_apply: false). The human operator will review and apply changes."
        end

        if @buffer_manager.dirty?
          applied = @buffer_manager.apply!
          @shell&.sync_context_and_ast(applied)
          "Successfully applied #{applied.size} modified file(s) to disk: #{applied.join(', ')}"
        else
          "No unapplied buffer changes to write (buffer is clean)."
        end
      end
    end

    class RepairRuntimeTool < BaseTool
      def initialize(runtime_manager: nil, lsp_manager: nil, adapter_registry: nil, overlay_storage: nil, config: nil, root_dir: Dir.pwd)
        super(
          name: "repair_runtime_service",
          aliases: ["fix_service", "repair_lsp", "repair_runner", "repair_runtime"],
          description: "Diagnose, adapt, or synthesize a replacement command/adapter for a failing runtime component " \
                       "(LSP, test runner, linter, or shell command) with pre-flight verification in an isolated sub-context",
          risk: :execute,
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
                type: "string",
                description: "Replacement or custom command string (optional, probed automatically if auto_probe: true)"
              },
              auto_probe: {
                type: "boolean",
                description: "Whether to automatically probe system binaries and candidate commands (default: true)"
              }
            },
            required: ["target", "language_or_type"]
          }
        )
        @runtime_manager = runtime_manager
        @lsp_manager = lsp_manager
        @adapter_registry = adapter_registry
        @overlay_storage = overlay_storage
        @config = config
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        target = (args["target"] || args[:target]).to_s.downcase.strip
        lang = (args["language_or_type"] || args[:language_or_type]).to_s.downcase.strip
        proposed_cmd = (args["proposed_command"] || args[:proposed_command]).to_s.strip
        auto_probe = if args["auto_probe"].nil?
                       args[:auto_probe].nil? || args[:auto_probe]
                     else
                       args["auto_probe"]
                     end

        return "Target and language_or_type must be provided" if target.empty? || lang.empty?

        # 1. Automatic Probing if proposed_cmd is not specified or auto_probe is requested
        if proposed_cmd.empty? && auto_probe
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
            return "Auto-probe failed to discover any installed candidate for #{target} (#{lang}). " \
                   "Candidates checked: [#{cand_str}]. Please provide a specific `proposed_command`."
          end
        end

        return "No command provided or discovered for #{target} (#{lang})" if proposed_cmd.empty?

        # 2. Pre-flight Verification in Isolated Sub-Context (ctx.extend())
        root_ctx = @runtime_manager&.context || Rubik::Runtime::Context.new
        sub_ctx = root_ctx.extend

        verified = false
        error_diagnostic = nil

        begin
          verified, error_diagnostic = verify_binary(target, lang, proposed_cmd, sub_ctx)
        rescue StandardError => e
          error_diagnostic = Rubik::Runtime::DiagnosticEngine.diagnose(
            cmd: proposed_cmd,
            exit_code: 1,
            stderr: "Exception during pre-flight sandbox check: #{e.message}"
          )
        ensure
          sub_ctx.dispose
        end

        return "Verification failed for #{target} (#{lang}):\n#{error_diagnostic&.format_for_llm}" unless verified

        # 3. Live Context Promotion & Subsystem Configuration (Zero-Downtime Hot Swapping)
        case target
        when "lsp"
          @config&.set("lsp.servers.#{lang}", proposed_cmd, persist: :project)
          if @lsp_manager
            @lsp_manager.stop_client(lang)
            @lsp_manager.start_client(lang)
            active_client = @lsp_manager.client_for(lang)
            root_ctx.provide("lsp:#{lang}", active_client || proposed_cmd)
          else
            root_ctx.provide("lsp:#{lang}", proposed_cmd)
          end
        when "test_runner"
          @config&.set("test.runners.#{lang}", proposed_cmd, persist: :project)
          if @adapter_registry
            adapter = @adapter_registry.get(lang)
            adapter.custom_test_cmd = proposed_cmd if adapter
          end
          root_ctx.provide("runner:#{lang}", proposed_cmd)
        when "linter"
          @config&.set("linter.commands.#{lang}", proposed_cmd, persist: :project)
          if @adapter_registry
            adapter = @adapter_registry.get(lang)
            adapter.custom_format_cmd = proposed_cmd if adapter
          end
          root_ctx.provide("linter:#{lang}", proposed_cmd)
        when "command"
          root_ctx.provide("command:#{lang}", proposed_cmd)
        end

        "✨ Successfully verified and promoted runtime service for #{target} (#{lang}): '#{proposed_cmd}'. " \
          "Service is now active and hot-swapped in the live context with zero downtime."
      end

      private

      def verify_binary(target, lang, proposed_cmd, sub_ctx)
        case target
        when "lsp"
          client = Rubik::LSP::Client.new(lang, root_dir: @root_dir, server_cmd: proposed_cmd)
          if client.available?
            sub_ctx.provide("lsp_probe:#{lang}", client)
            [true, nil]
          else
            [false, Rubik::Runtime::DiagnosticEngine.diagnose(
              cmd: proposed_cmd,
              exit_code: 127,
              stderr: "Pre-flight check failed: LSP binary '#{client.binary_name}' not available on system"
            )]
          end
        when "test_runner"
          if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
            sub_ctx.provide("runner_probe:#{lang}", proposed_cmd)
            [true, nil]
          else
            [false, Rubik::Runtime::DiagnosticEngine.diagnose(
              cmd: proposed_cmd,
              exit_code: 127,
              stderr: "Pre-flight check failed: Test runner executable not found in PATH"
            )]
          end
        when "linter"
          if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
            sub_ctx.provide("linter_probe:#{lang}", proposed_cmd)
            [true, nil]
          else
            [false, Rubik::Runtime::DiagnosticEngine.diagnose(
              cmd: proposed_cmd,
              exit_code: 127,
              stderr: "Pre-flight check failed: Linter/formatter executable not found in PATH"
            )]
          end
        when "command"
          if Rubik::Runtime::Discovery.binary_available?(proposed_cmd)
            sub_ctx.provide("command_probe:#{lang}", proposed_cmd)
            [true, nil]
          else
            [false, Rubik::Runtime::DiagnosticEngine.diagnose(
              cmd: proposed_cmd,
              exit_code: 127,
              stderr: "Pre-flight check failed: Command executable not found in PATH"
            )]
          end
        else
          [false, Rubik::Runtime::DiagnosticEngine.diagnose(
            cmd: proposed_cmd,
            exit_code: 1,
            stderr: "Unknown target component type: #{target}"
          )]
        end
      end
    end

    class FinishTool < BaseTool
      def initialize
        super(
          name: "finish",
          aliases: ["complete", "done", "task_complete", "exit"],
          description: "Signal task completion with final message",
          risk: :execute,
          params_schema: { type: "object", properties: { message: { type: "string" } } }
        )
      end

      def execute(args = {})
        args["message"] || args[:message] || "Task finished"
      end
    end
  end
end
