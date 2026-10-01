# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Tool for controlling long-running asynchronous background processes
    # (servers, test runners, compilers, watch modes) (Plan 93).
    class ManageTaskTool < BaseTool
      REQUIRES = [Rubik::Coeffects::TASK_MANAGER].freeze

      attr_accessor :task_manager, :runtime_context

      DECLARATION = Declaration.new(
        name: "manage_task", aliases: ["task", "tasks", "background_task", "bg_task"],
        description: "Manage asynchronous background processes (servers, builders, long test runs). " \
                     "Actions: 'start', 'list', 'status', 'logs', 'send_input', 'kill'.",
        risk: :execute, maestro_blocked: true, # gate scopes to action 'start'; orchestration actions stay direct
        params_schema: {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: ["start", "list", "status", "logs", "send_input", "kill"],
              description: "Action to perform: 'start', 'list', 'status', 'logs', 'send_input', or 'kill'"
            },
            task_id: { type: "string", description: "The task ID (e.g. 'task-1'). Required for status, logs, send_input, kill." },
            command: { type: "string", description: "The shell command to run. Required for 'start'." },
            input: { type: "string", description: "Input text to send to stdin. Required for 'send_input'." },
            tail: { type: "integer", description: "Number of lines to read for 'logs' (default: 50)." }
          },
          required: ["action"]
        }
      )
      def initialize(task_manager: nil, guard: nil, runtime_context: nil)
        super(DECLARATION)
        @task_manager = task_manager
        @guard = guard
        @runtime_context = runtime_context
      end

      def execute(args = {})
        action = (args["action"] || args[:action]).to_s.downcase.strip
        task_mgr = resolve_task_manager
        return ToolOutput.error("TaskManager is not available in the runtime context.") unless task_mgr

        case action
        when "start"
          handle_start(task_mgr, args)
        when "list"
          handle_list(task_mgr)
        when "status"
          handle_status(task_mgr, args)
        when "logs"
          handle_logs(task_mgr, args)
        when "send_input"
          handle_send_input(task_mgr, args)
        when "kill"
          handle_kill(task_mgr, args)
        else
          ToolOutput.error("Unknown action '#{action}'. Allowed actions: start, list, status, logs, send_input, kill.")
        end
      rescue Rubik::Security::BlockedWriteError => e
        require_relative "exec" unless defined?(Rubik::Tools::RunCommandTool)
        ToolOutput.error(Rubik::Tools::RunCommandTool.blocked_guidance(e))
      rescue StandardError => e
        ToolOutput.error("manage_task error (#{action}): #{e.message}")
      end

      private

      def resolve_task_manager
        @task_manager || (@runtime_context.respond_to?(:get) ? Rubik::Coeffects.get(@runtime_context, Rubik::Coeffects::TASK_MANAGER) : nil)
      end

      def extract_task_id(args)
        (args["task_id"] || args[:task_id] || args["taskId"] || args[:taskId]).to_s.strip
      end

      def extract_command(args)
        (args["command"] || args[:command] || args["cmd"] || args[:cmd]).to_s.strip
      end

      def handle_start(task_mgr, args)
        cmd = extract_command(args)
        return ToolOutput.error("Missing required parameter 'command' for action 'start'.") if cmd.empty?

        task = task_mgr.start(cmd, ctx: @runtime_context)
        "Task started: #{task.id} (PID #{task.pid})\nCommand: #{task.command}\nStatus: #{task.status.to_s.upcase}"
      end

      def handle_list(task_mgr)
        tasks = task_mgr.list.sort_by { |t| t.started_at || Time.at(0) }
        return "No background tasks currently running or tracked." if tasks.empty?

        lines = ["=== Background Tasks (#{tasks.size}) ==="]
        tasks.each do |t|
          dur = t.running? ? "up #{t.uptime.round(1)}s" : "exit #{t.exit_code}"
          lines << "  • [#{t.id}] #{t.status.to_s.upcase} (PID #{t.pid}, #{dur}): #{t.command}"
        end
        lines.join("\n")
      end

      def handle_status(task_mgr, args)
        task_id = extract_task_id(args)
        return ToolOutput.error("Missing required parameter 'task_id' for action 'status'.") if task_id.empty?

        task = task_mgr.get(task_id)
        return ToolOutput.error("Task '#{task_id}' not found.") unless task

        <<~STATUS.chomp
          Task: #{task.id}
          Status: #{task.status.to_s.upcase}
          PID: #{task.pid}
          Uptime: #{task.uptime.round(1)}s
          Exit Code: #{task.exit_code.inspect}
          Command: #{task.command}
        STATUS
      end

      def handle_logs(task_mgr, args)
        task_id = extract_task_id(args)
        return ToolOutput.error("Missing required parameter 'task_id' for action 'logs'.") if task_id.empty?

        tail = (args["tail"] || args[:tail] || 50).to_i
        task = task_mgr.get(task_id)
        return ToolOutput.error("Task '#{task_id}' not found.") unless task

        lines = task.ring_buffer.tail(tail)
        return "No logs recorded for task '#{task_id}' yet." if lines.empty?

        "=== Logs for #{task.id} (last #{lines.size} lines) ===\n#{lines.join("\n")}"
      end

      def handle_send_input(task_mgr, args)
        task_id = extract_task_id(args)
        return ToolOutput.error("Missing required parameter 'task_id' for action 'send_input'.") if task_id.empty?

        input = args["input"] || args[:input]
        return ToolOutput.error("Missing required parameter 'input' for action 'send_input'.") if input.nil?

        ok = task_mgr.send_input(task_id, input)
        if ok
          "Input sent to task '#{task_id}'."
        else
          ToolOutput.error("Failed to send input to task '#{task_id}'. Task may not be running or stdin is closed.")
        end
      end

      def handle_kill(task_mgr, args)
        task_id = extract_task_id(args)
        return ToolOutput.error("Missing required parameter 'task_id' for action 'kill'.") if task_id.empty?

        task = task_mgr.get(task_id)
        return ToolOutput.error("Task '#{task_id}' not found.") unless task

        if task.status == :running
          task_mgr.kill(task_id)
          "Task '#{task_id}' killed. (PID #{task.pid})"
        else
          "Task '#{task_id}' is already #{task.status.to_s.upcase} (exit code: #{task.exit_code.inspect})."
        end
      end
    end
  end
end
