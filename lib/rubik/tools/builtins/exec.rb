# frozen_string_literal: true

require "stringio"
require_relative "../base"
require_relative "../output"

module Rubik
  module Tools
    class RunTestsTool < BaseTool
      def initialize(adapter_registry, context_index = nil, root_dir: Dir.pwd, config: nil)
        super(
          name: "run_tests",
          aliases: ["test", "run_test_suite"],
          description: "Run the project test suite using the appropriate language adapter. " \
                       "Use apply_buffer to persist buffer edits before testing so tests see the latest changes.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              language: { type: "string", description: "Language test runner to use (e.g. ruby, go, rust, zig, python, c, crystal) (optional)" }
            }
          }
        )
        @adapter_registry = adapter_registry
        @context_index = context_index
        @root_dir = File.expand_path(root_dir)
        @config = config
      end

      def execute(args = {})
        lang = args["language"] || args[:language]
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

        res = adapter.run_tests(@root_dir)
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

        require_relative "../../adapter/generic" unless defined?(Rubik::Adapter::GenericAdapter)
        new_adapter = Rubik::Adapter::GenericAdapter.new(lang_key, test_cmd: candidate_cmd)
        new_adapter.config = @config
        @adapter_registry&.register(lang_key, new_adapter)
        new_adapter
      end
    end

    class RunCommandTool < BaseTool
      def initialize(guard:, runner:, root_dir: Dir.pwd)
        super(
          name: "run_command",
          aliases: ["bash", "sh", "execute_command", "cmd"],
          description: "Execute a safe shell command inside the sandbox runner in the project working directory (do not use cd). " \
                       "Unknown or dangerous commands are blocked fail-closed; the human operator can allowlist specific command " \
                       "prefixes via the operator-only !allow-cmd REPL command.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "Shell command to run directly in the project directory" },
              timeout: { type: "integer", description: "Timeout in seconds (optional, default: 30)" }
            },
            required: ["command"]
          }
        )
        @guard = guard
        @runner = runner
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        cmd = (args["command"] || args[:command]).to_s.strip
        # Timeout contract: runners expose their config via a public `config`
        # reader (Sandbox::Runner does via attr_reader). Never reach into an
        # arbitrary object with instance_variable_get — that couples us to an
        # ivar name we do not own and silently falls back if it is ever renamed.
        cfg = @runner.config if @runner.respond_to?(:config)
        cfg_timeout = cfg&.fetch("tools.timeout_seconds", 30) || 30
        timeout = (args["timeout"] || args[:timeout] || cfg_timeout).to_i

        @guard.verify_command_safety!(cmd)
        res = @runner.run(cmd, timeout: timeout, chdir: @root_dir)
        status = res[:ok] ? "OK" : "EXIT #{res[:exit_code]}"
        # Shell tag (Plan 55 D-5) teaches the model which interpreter ran the
        # command; drivers that resolve no shell simply omit it.
        shell_tag = res[:shell] ? " (#{res[:shell]})" : ""
        out = "[#{status}]#{shell_tag} #{res[:output]}"
        out += "\n#{res[:isolation]}" if res[:isolation]

        unless res[:ok]
          require_relative "../../runtime/diagnostic_engine" unless defined?(Rubik::Runtime::DiagnosticEngine)
          diag = Rubik::Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd)
          out += "\n\n#{diag.format_for_llm}" if diag
        end
        out
      rescue Rubik::Security::BlockedWriteError => e
        # Prefix stays first: StepExecutor::ERROR_PREFIXES classifies by start_with?.
        ToolOutput.error(Rubik::Tools::RunCommandTool.blocked_guidance(e))
      rescue StandardError => e
        ToolOutput.error("Command error: #{e.message}")
      end

      # Situation-specific blocked-command guidance (replaces the one-size
      # canned message). The operator-facing allowlist syntax is always a
      # copy-pasteable one-liner: `!allow-cmd add "<command>"`.
      def self.blocked_guidance(err)
        cmd = err.respond_to?(:blocked_command) ? err.blocked_command : nil
        rule = err.respond_to?(:rule_name) ? err.rule_name : nil
        quoted = cmd ? "\"#{cmd}\"" : nil
        # Unstructured raises (critical-write, sandbox chdir gate) carry all
        # their context in #message — never discard it behind "rule: unknown".
        message = err.respond_to?(:message) ? err.message : nil
        structural = cmd || rule

        lines = if !structural && message
                  if /chdir directory/i.match?(message)
                    # Sandbox path fence: the working gate is !allow-dir, not
                    # !allow-cmd — point the operator at the right one.
                    path = message[/^Execution blocked: chdir directory '([^']+)'/, 1]
                    [
                      "Security blocked: #{message}",
                      "If intended, the operator can extend the sandbox once:",
                      "  !allow-dir add \"#{path || "<directory>"}\""
                    ]
                  else
                    base = ["Security blocked: #{message}"]
                    base << "If genuinely required and safe, the operator can allowlist it once:"
                    base << "  !allow-cmd add #{quoted}" if quoted
                    base
                  end
                elsif cmd && err.respond_to?(:probe_like) && err.probe_like
                  # Probe branch first: `python3 --version` is probe-shaped and
                  # must not be hijacked by the text-munging variant below.
                  [
                    "Security blocked: `#{cmd}` is blocklisted by the base rule for shell",
                    "interpreters, even for version checks.",
                    "This looks like a safe read-only probe. If intended, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                elsif text_munging?(cmd)
                  [
                    "Security blocked: shell text-munging is not allowed for file edits.",
                    "Use the native tools instead: read_file → replace_file_content / write_file,",
                    "then verify with lsp_diagnostics or run_tests.",
                    "If genuinely required, the operator can allowlist the exact command:",
                    "  !allow-cmd add #{quoted}"
                  ]
                else
                  [
                    "Security blocked: `#{cmd || "command"}` was denied (rule: #{rule || "unknown"}).",
                    "If genuinely required and safe, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                end

        # Never print the generic text-munging boilerplate for probe scenarios.
        lines.compact.join("\n")
      end

      # (b) variant trigger: file-editing via text-munging interpreters.
      def self.text_munging?(cmd)
        return false if cmd.to_s.strip.empty?

        %w[sed awk perl python3 python ruby].include?(cmd.split(/\s+/).first.to_s.downcase)
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

      def initialize(shell = nil)
        super(
          name: "exec_repl_command",
          aliases: ["repl_command", "exec_repl", "repl"],
          description: "Execute the session-safe Rubik REPL commands published in <agent_commands> of the system prompt " \
                       "(runtime configuration, buffer review and rollback, context/step self-management, " \
                       "runtime introspection, code validation). Do NOT use this tool for reading files, writing code, or " \
                       "running tests. Use direct tools (read_file, write_file, run_tests, run_command) instead.",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "The full REPL command string to execute (e.g. '!diff', '!context scan', '!undo')" }
            },
            required: ["command"]
          }
        )
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
        was_agent_call = @shell.respond_to?(:agent_caller=)
        @shell.agent_caller = true if was_agent_call
        begin
          output_str = @shell.capture_output { @shell.execute_input(cmd) }.strip
        ensure
          @shell.agent_caller = false if was_agent_call
        end
        output_str.empty? ? "Command #{cmd} executed with no output." : output_str
      end
    end
  end
end
