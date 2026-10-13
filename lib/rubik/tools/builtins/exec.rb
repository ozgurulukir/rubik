# frozen_string_literal: true

require "stringio"
require_relative "../base"
require_relative "../output"
require_relative "../../security/blocked_guidance"

module Rubik
  module Tools
    class RunTestsTool < BaseTool
      DECLARATION = Declaration.new(
        name: "run_tests", aliases: ["test", "run_test_suite"],
        description: "Run the project test suite using the appropriate language adapter. " \
                     "Specify 'path' to target a specific test file or directory fast. " \
                     "Use apply_buffer to persist buffer edits before testing so tests see the latest changes.",
        risk: :execute, archetypes: [:coder], maestro_blocked: true,
        params_schema: {
          type: "object",
          properties: {
            language: { type: "string", description: "Language test runner to use (e.g. ruby, go, rust, zig, python, c, crystal) (optional)" },
            path: { type: "string", description: "Target test file or directory path (e.g. 'test/unit/test_lsp_client.rb') to run fast (optional)" },
            timeout: { type: "integer", description: "Timeout in seconds (optional, default: 30)" }
          }
        }
      )
      def initialize(adapter_registry, context_index = nil, root_dir: Dir.pwd, config: nil, guard: nil)
        super(DECLARATION)
        @adapter_registry = adapter_registry
        @context_index = context_index
        @root_dir = File.expand_path(root_dir)
        @config = config
        @guard = guard
      end

      def execute(args = {})
        lang = args["language"] || args[:language]
        path = args["path"] || args[:path]
        timeout = args["timeout"] || args[:timeout]
        if lang.nil? || lang.to_s.strip.empty?
          langs = @context_index&.languages || []
          lang = langs.first || "ruby"
        end

        lang_key = lang.to_s.downcase.strip
        adapter = @adapter_registry&.get(lang_key)
        adapter ||= synthesize_adapter(lang_key)

        unless adapter
          return ToolOutput.error(
            <<~ERR.chomp
              -- NO TEST ADAPTER CONFIGURED ---------------------------------------
              No test runner is configured for language '#{lang}'.

              To configure a test runner automatically, call:
                repair_runtime_service(target: "test_runner", language_or_type: "#{lang}", proposed_command: "<command>")

              Or execute your test command directly via:
                run_command(command: "<command>")
            ERR
          )
        end

        clean_path = path.to_s.strip
        clean_path = nil if clean_path.empty?
        eff_timeout = timeout.to_i if timeout&.to_i&.positive?

        res = if clean_path || eff_timeout
                begin
                  adapter.run_tests(@root_dir, path: clean_path, timeout: eff_timeout)
                rescue ArgumentError => e
                  raise e unless e.message =~ /wrong number of arguments|unknown keyword/

                  adapter.run_tests(@root_dir)
                end
              else
                adapter.run_tests(@root_dir)
              end
        status = res[:ok] ? "PASSED" : "FAILED"
        out = "Test run [#{status}] (#{res[:duration]}s):\n#{res[:output]}"

        out += "\n\n#{res[:diagnostic].format_for_llm}" if !res[:ok] && res[:diagnostic]
        out
      end

      private

      def synthesize_adapter(lang_key)
        configured_cmd = @config&.fetch("test.runners.#{lang_key}")
        candidate_cmd = if configured_cmd && !configured_cmd.to_s.strip.empty?
                          configured_cmd
                        else
                          require_relative "../../runtime/discovery" unless defined?(Rubik::Runtime::Discovery)
                          candidates = Rubik::Runtime::Discovery.test_runner_candidates(lang_key, root_dir: @root_dir, config: @config)
                          candidates.find { |c| Rubik::Runtime::Discovery.binary_available?(c, root_dir: @root_dir) }
                        end

        return nil unless candidate_cmd

        # Fail-closed gate: a test-runner command discovered from operator
        # config or heuristics is an arbitrary shell command, verified by the
        # GenericAdapter constructor through the shared session guard BEFORE a
        # runnable adapter exists — otherwise RunTestsTool could fabricate an
        # adapter for any dangerous command (e.g. "rm -rf /") with no
        # classification. validation_shell: "bash" classifies the candidate as
        # the shell command it is (run_tests itself is one), not as Ruby
        # source. The shared guard (registry injects it) carries the operator
        # allowlist, so !allow-cmd add "python3 -m pytest" can rescue a runner
        # here; the lazy fallback (silent audit, zero policy) serves only
        # standalone tool constructions.
        require_relative "../../security/guard" unless defined?(Rubik::Security::Guard)
        security_guard = @guard || Rubik::Security::Guard.new(audit_log_path: nil)

        require_relative "../../adapter/generic" unless defined?(Rubik::Adapter::GenericAdapter)
        new_adapter = Rubik::Adapter::GenericAdapter.new(lang_key, test_cmd: candidate_cmd,
                                                                   guard: security_guard, validation_shell: "bash")
        new_adapter.config = @config
        @adapter_registry&.register(lang_key, new_adapter)
        new_adapter
      end
    end

    class RunCommandTool < BaseTool
      attr_accessor :task_manager, :runtime_context

      DECLARATION = Declaration.new(
        name: "run_command", aliases: ["bash", "sh", "execute_command", "cmd"],
        description: "Execute a safe shell command inside the sandbox runner in the project working directory (do not use cd). " \
                     "Unknown or dangerous commands are blocked fail-closed; the human operator can allowlist specific command " \
                     "prefixes via the operator-only !allow-cmd REPL command.",
        risk: :execute, archetypes: [:coder], write_grant: true, maestro_blocked: true, # maestro: command execution belongs to coder subagents
        params_schema: {
          type: "object",
          properties: {
            command: { type: "string", description: "Shell command to run directly in the project directory" },
            timeout: { type: "integer", description: "Timeout in seconds (optional, default: 30)" },
            background: { type: "boolean", description: "Run command asynchronously in the background as a managed task (optional)" }
          },
          required: ["command"]
        }
      )
      def initialize(guard:, runner:, root_dir: Dir.pwd, task_manager: nil, runtime_context: nil)
        super(DECLARATION)
        @guard = guard
        @runner = runner
        @root_dir = File.expand_path(root_dir)
        @task_manager = task_manager
        @runtime_context = runtime_context
      end

      def execute(args = {})
        cmd = (args["command"] || args[:command]).to_s.strip
        background = args["background"] || args[:background]
        return execute_background(cmd) if background

        timeout = effective_timeout(args)
        @guard.verify_command_safety!(cmd)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        res = @runner.run(cmd, timeout: timeout, chdir: @root_dir)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        command_result(cmd, res, duration_ms: duration_ms)
      rescue Rubik::Security::BlockedWriteError => e
        # Authorization denial (issue #127): nothing executed, so no process
        # exit code is fabricated — the metadata says denied / not executed.
        # The prefix stays first for display consumers (StepExecutor::ERROR_PREFIXES).
        Rubik::Tools::Result.new(
          tool_name: "run_command", status: :error,
          output: Rubik::Tools::RunCommandTool.blocked_guidance(e),
          error: "command denied by security policy (not executed)",
          exit_code: nil, metadata: { "executed" => false, "denied" => "authorization" }
        )
      rescue StandardError => e
        Rubik::Tools::Result.new(
          tool_name: "run_command", status: :error,
          output: "Command error: #{e.message}", error: e.message,
          exit_code: nil, metadata: { "executed" => false }
        )
      end

      # Stable public seam (RunCommandTool#execute, ManageTaskTool, tests and
      # dev/review_fix_check call it). The renderer lives in the security
      # domain next to the error it renders: Rubik::Security::BlockedGuidance
      # — also keeps this file under the builtin line budget.
      def self.blocked_guidance(err)
        Rubik::Security::BlockedGuidance.render(err)
      end

      private

      def execute_background(cmd)
        task_mgr = @task_manager ||
                   (@runtime_context.respond_to?(:get) ? Rubik::Coeffects.get(@runtime_context, Rubik::Coeffects::TASK_MANAGER) : nil)
        if task_mgr.nil?
          return Rubik::Tools::Result.new(tool_name: "run_command", status: :error,
                                          output: "TaskManager is not available to run commands in background.",
                                          error: "task manager unavailable",
                                          metadata: { "executed" => false, "background" => true })
        end

        @guard.verify_command_safety!(cmd)
        task = task_mgr.start(cmd, chdir: @root_dir, ctx: @runtime_context)
        text = "Command dispatched to background task [#{task.id}] (PID #{task.pid}): #{cmd}\n" \
               "Use `manage_task` with action 'status' or 'logs' to inspect."
        Rubik::Tools::Result.new(tool_name: "run_command", status: :ok, output: text, exit_code: nil,
                                 metadata: { "executed" => true, "background" => true, "task_id" => task.id })
      end

      def effective_timeout(args)
        # Timeout contract: runners expose their config via a public `config`
        # reader (Sandbox::Runner does via attr_reader). Never reach into an
        # arbitrary object with instance_variable_get — that couples us to an
        # ivar name we do not own and silently falls back if it is ever renamed.
        cfg = @runner.config if @runner.respond_to?(:config)
        cfg_timeout = cfg&.fetch("tools.timeout_seconds", 30) || 30
        (args["timeout"] || args[:timeout] || cfg_timeout).to_i.clamp(1, 600)
      end

      # The structured command outcome (issue #127): the display text keeps
      # the historical [OK]/[EXIT n] prefix and diagnostics, while the machine
      # fields (status / exit_code / truncated / metadata) ride the Result
      # contract through BOTH dispatch paths — no display-text parsing.
      def command_result(cmd, res, duration_ms:)
        exit_code = res[:exit_code]
        timed_out = exit_code.to_i == 124
        status_text = res[:ok] ? "OK" : "EXIT #{exit_code}"
        shell_tag = res[:shell] ? " (#{res[:shell]})" : ""
        out = "[#{status_text}]#{shell_tag} #{res[:output]}"
        out += "\n#{res[:isolation]}" if res[:isolation]

        diagnostic = nil
        unless res[:ok]
          require_relative "../../runtime/diagnostic_engine" unless defined?(Rubik::Runtime::DiagnosticEngine)
          diagnostic = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd)
          out += "\n\n#{diagnostic.format_for_llm}" if diagnostic
        end

        timeout_suffix = timed_out ? " (timed out)" : ""
        error_message = res[:ok] ? nil : "command exited with status #{exit_code}#{timeout_suffix}"

        Rubik::Tools::Result.new(
          tool_name: "run_command", status: res[:ok] ? :ok : :error, output: out,
          error: error_message, exit_code: exit_code, duration_ms: duration_ms,
          metadata: { "executed" => true, "timed_out" => timed_out,
                      "diagnostic_category" => diagnostic && diagnostic.category.to_s,
                      "shell" => res[:shell].to_s, "driver" => res[:driver].to_s }.reject { |_k, v| v.nil? || v == "" }
        )
      end
    end

    class ExecReplCommandTool < BaseTool
      REDIRECT_MAP = {
        "test" => "run_tests",
        "sh" => "run_command",
        "read" => "read_file",
        "write" => "write_file",
        "apply" => "apply_buffer",
        "symbols" => "search_symbols",
        "outline" => "get_outline",
        "refs" => "find_references",
        "ast" => "get_symbol / get_outline",
        "diagnostics" => "lsp_diagnostics"
      }.freeze

      # Commands that terminate or erase the interactive session. Hard-blocked
      # for the agent regardless of audience metadata (Plan 53 D-3).
      SESSION_CONTROL_COMMANDS = ["quit", "exit", "clear", "reset"].freeze

      DECLARATION = Declaration.new(
        name: "exec_repl_command", aliases: ["repl_command", "exec_repl", "repl"],
        description: "Execute the session-safe Rubik REPL commands published in <agent_commands> of the system prompt " \
                     "(runtime configuration, buffer review and rollback, context/step self-management, " \
                     "runtime introspection, code validation). Do NOT use this tool for reading files, writing code, or " \
                     "running tests. Use direct tools (read_file, write_file, run_tests, run_command) instead.",
        risk: :execute, maestro_blocked: false, # session-safe REPL plane only — file/test/shell work stays delegated
        params_schema: {
          type: "object",
          properties: {
            command: { type: "string", description: "The full REPL command string to execute (e.g. '!diff', '!context scan', '!undo')" }
          },
          required: ["command"]
        }
      )
      def initialize(shell = nil)
        super(DECLARATION)
        @shell = shell
      end

      def execute(args = {})
        cmd = (args["command"] || args[:command]).to_s.strip
        return ToolOutput.error("No command provided.") if cmd.empty?
        return ToolOutput.error("REPL shell is not connected.") unless @shell

        # Format command with leading ! if missing
        cmd = "!#{cmd}" unless cmd.start_with?("!")

        base_cmd = cmd.split.first.to_s.downcase.delete_prefix("!")

        if REDIRECT_MAP.key?(base_cmd)
          return ToolOutput.error("Notice: Please use native tool '#{REDIRECT_MAP[base_cmd]}' directly instead of exec_repl_command('#{cmd}'). " \
                                  "REPL commands are not suitable for autonomous tool invocation for this action.")
        end

        if SESSION_CONTROL_COMMANDS.include?(base_cmd)
          return ToolOutput.error("Blocked: '!#{base_cmd}' would terminate or reset the user's interactive session and is reserved " \
                                  "for the human operator. Continue your task with native tools and call the 'finish' tool when done.")
        end

        # Prevent recursive loops of plan/goal inside plan/goal; steer back to the loop contract
        if ["plan", "goal"].include?(base_cmd)
          return ToolOutput.error("Nested #{cmd.split.first} invocation inside tool call is blocked. You are already running inside " \
                                  "the agent loop: continue the current task with native tools and call the 'finish' tool when the goal is complete.")
        end

        meta = @shell.commands[base_cmd]
        if meta.nil?
          return ToolOutput.error("Unknown REPL command '!#{base_cmd}'. Rubik does not have a '!#{base_cmd}' command. " \
                                  "To explore files, read code, or perform a review, use direct tools " \
                                  "('list_files', 'read_file', 'search_symbols', 'get_outline') instead of REPL commands.")
        end

        # Fail-closed allowlist: any audience value outside this set stays unpublished and un-invokable.
        unless [:agent, :both].include?(meta[:audience])
          return ToolOutput.error("Notice: '!#{base_cmd}' is reserved for the human operator (#{meta[:description].to_s.downcase}). " \
                                  "For file, code, test, and shell operations use your direct tools instead.")
        end

        # Caller-source proof for security-sensitive REPL commands (Plan:
        # komut-allowlist Paket D): commands like `!config set security.*`
        # refuse mutations when the caller is the agent, not the human.
        has_setter = @shell.respond_to?(:agent_caller=)
        prev_caller = @shell.respond_to?(:agent_caller) ? @shell.agent_caller : false
        @shell.agent_caller = true if has_setter
        begin
          output_str = @shell.capture_output { @shell.execute_input(cmd) }.strip
        ensure
          @shell.agent_caller = prev_caller if has_setter
        end
        output_str.empty? ? "Command #{cmd} executed with no output." : output_str
      end
    end
  end
end
