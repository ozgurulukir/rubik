# frozen_string_literal: true

require "stringio"
require_relative "../base"

module Rubik
  module Tools
    class RunTestsTool < BaseTool
      def initialize(adapter_registry, context_index = nil, root_dir: Dir.pwd)
        super(
          name: "run_tests",
          aliases: %w[test run_test_suite],
          description: "Run the project test suite using the appropriate language adapter",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              language: { type: "string", description: "Language test runner to use (e.g. ruby, go, rust, zig, python, c) (optional)" }
            }
          }
        )
        @adapter_registry = adapter_registry
        @context_index = context_index
        @root_dir = File.expand_path(root_dir)
      end

      def execute(args = {})
        lang = args["language"] || args[:language]
        unless lang
          langs = @context_index&.languages || []
          lang = langs.first || "ruby"
        end

        adapter = @adapter_registry.get(lang.to_s.downcase)
        return "No adapter available for language '#{lang}'" unless adapter

        res = adapter.run_tests(@root_dir)
        status = res[:ok] ? "PASSED" : "FAILED"
        "Test run [#{status}] (#{res[:duration]}s):\n#{res[:output]}"
      end
    end

    class RunCommandTool < BaseTool
      def initialize(guard:, runner:, root_dir: Dir.pwd)
        super(
          name: "run_command",
          aliases: %w[bash sh execute_command cmd],
          description: "Execute a safe shell command inside the sandbox runner in the project working directory (do not use cd)",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "Shell command to run directly in the project directory" },
              timeout: { type: "integer", description: "Timeout in seconds (optional, default: 15)" }
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
        timeout = (args["timeout"] || args[:timeout] || 15).to_i

        @guard.verify_command_safety!(cmd)
        res = @runner.run(cmd, timeout: timeout, chdir: @root_dir)
        status = res[:ok] ? "OK" : "EXIT #{res[:exit_code]}"
        # Shell tag (Plan 55 D-5) teaches the model which interpreter ran the
        # command; drivers that resolve no shell simply omit it.
        shell_tag = res[:shell] ? " (#{res[:shell]})" : ""
        "[#{status}]#{shell_tag} #{res[:output]}"
      rescue Rubik::Security::BlockedWriteError => e
        "Security blocked: #{e.message}"
      rescue StandardError => e
        "Command error: #{e.message}"
      end
    end

    class ExecReplCommandTool < BaseTool
      REDIRECT_MAP = {
        "test"    => "run_tests",
        "sh"      => "run_command",
        "read"    => "read_file",
        "write"   => "write_file",
        "apply"   => "apply_buffer",
        "symbols" => "search_symbols",
        "outline" => "get_outline",
        "refs"    => "find_references",
        "ast"     => "get_symbol / get_outline",
        "diagnostics" => "lsp_diagnostics"
      }.freeze

      # Commands that terminate or erase the interactive session. Hard-blocked
      # for the agent regardless of audience metadata (Plan 53 D-3).
      SESSION_CONTROL_COMMANDS = ["quit", "exit", "clear", "reset"].freeze

      def initialize(shell = nil)
        super(
          name: "exec_repl_command",
          aliases: %w[repl_command exec_repl repl],
          description: "Execute the session-safe Rubik REPL commands published in <agent_commands> of the system prompt " \
                       "(runtime configuration, buffer review and rollback, context/step self-management, " \
                       "runtime introspection, code validation). Do NOT use this tool for reading files, writing code, or " \
                       "running tests—use direct tools (read_file, write_file, run_tests, run_command) instead.",
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
        return "No command provided" if cmd.empty?
        return "REPL shell is not connected" unless @shell

        # Format command with leading ! if missing
        cmd = "!#{cmd}" unless cmd.start_with?("!")

        base_cmd = cmd.split.first.to_s.downcase.delete_prefix("!")

        if REDIRECT_MAP.key?(base_cmd)
          return "Notice: Please use native tool '#{REDIRECT_MAP[base_cmd]}' directly instead of exec_repl_command('#{cmd}'). REPL commands are not suitable for autonomous tool invocation for this action."
        end

        if SESSION_CONTROL_COMMANDS.include?(base_cmd)
          return "Blocked: '!#{base_cmd}' would terminate or reset the user's interactive session and is reserved " \
                 "for the human operator. Continue your task with native tools and call the 'finish' tool when done."
        end

        # Prevent recursive loops of plan/goal inside plan/goal; steer back to the loop contract
        if ["plan", "goal"].include?(base_cmd)
          return "Nested #{cmd.split.first} invocation inside tool call is blocked. You are already running inside " \
                 "the agent loop: continue the current task with native tools and call the 'finish' tool when the goal is complete."
        end

        meta = @shell.commands[base_cmd]
        if meta.nil?
          return "Unknown REPL command '!#{base_cmd}'. Rubik does not have a '!#{base_cmd}' command. To explore files, read code, or perform a review, use direct tools ('list_files', 'read_file', 'search_symbols', 'get_outline') instead of REPL commands."
        end

        # Fail-closed allowlist: any audience value outside this set stays unpublished and un-invokable.
        unless [:agent, :both].include?(meta[:audience])
          return "Notice: '!#{base_cmd}' is reserved for the human operator (#{meta[:description].to_s.downcase}). " \
                 "For file, code, test, and shell operations use your direct tools instead."
        end

        captured_out = StringIO.new
        orig_out = @shell.instance_variable_get(:@output)
        @shell.instance_variable_set(:@output, captured_out)

        begin
          @shell.execute_input(cmd)
        ensure
          @shell.instance_variable_set(:@output, orig_out)
        end

        output_str = captured_out.string.strip
        output_str.empty? ? "Command #{cmd} executed with no output." : output_str
      end
    end
  end
end
