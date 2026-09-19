# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    class InspectRuntimeTool < BaseTool
      def initialize(runtime_manager = nil, tool_registry = nil, shell = nil)
        super(
          name: "inspect_runtime",
          aliases: ["runtime_status", "inspect_fibers"],
          description: "Inspect the Spatiotemporal Composability runtime state: active/pending fibers, coeffects, registered services, tools, and commands",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              target: { type: "string", enum: ["all", "fibers", "services", "tools", "commands", "tasks"], description: "Component to inspect (default: all)" }
            }
          }
        )
        @runtime_manager = runtime_manager
        @tool_registry = tool_registry
        @shell = shell
      end

      def execute(args = {})
        target = (args["target"] || args[:target] || "all").to_s.downcase

        lines = ["=== Rubik Spatiotemporal Runtime Diagnostics ==="]

        if ["all", "services"].include?(target) && @runtime_manager
          root_ctx = @runtime_manager.context
          services = root_ctx.services
          lines << "\n[Services / Coeffects Active (#{services.size})]:"
          services.each { |k, v| lines << "  • #{k.to_s.ljust(12)} -> #{v.class}" }
          lines << "  (LIFO Accumulator Depth: #{root_ctx.disposable_count} inverse disposables)"
        end

        if ["all", "fibers"].include?(target) && @runtime_manager
          active = @runtime_manager.active_fibers
          pending = @runtime_manager.pending_fibers
          failed = @runtime_manager.fibers.values.select { |f| f.state == :failed }
          lines << "\n[Fibers (#{active.size} Active, #{pending.size} Pending, #{failed.size} Failed)]:"
          active.each { |f| lines << "  🟢 ACTIVE : #{f.name} (injects: #{f.inject.join(', ')})" }
          pending.each do |f|
            missing = f.inject.reject { |dep| @runtime_manager.context.has?(dep) }
            lines << "  ⏳ PENDING: #{f.name} (waiting on: #{missing.join(', ')})"
          end
          failed.each { |f| lines << "  🔴 FAILED : #{f.name} (error: #{f.last_error&.message})" }
        end

        if ["all", "tools"].include?(target) && @tool_registry
          tools = @tool_registry.list
          lines << "\n[Tool Registry (#{tools.size} Registered Tools)]:"
          tools.each { |t| lines << "  ⚙ #{t.name.ljust(22)} [#{t.risk}] - #{t.description[0..60]}" }
        end

        if ["all", "commands"].include?(target) && @shell
          cmds = @shell.commands
          lines << "\n[REPL Bang Commands (#{cmds.size} Registered)]:"
          cmds.sort.each { |name, meta| lines << "  !#{name.ljust(16)} : #{meta[:description]}" }
        end

        task_mgr = (Rubik::Coeffects.get(@runtime_manager.context, Rubik::Coeffects::TASK_MANAGER) if @runtime_manager&.context.respond_to?(:get))
        task_mgr ||= @shell.task_manager if @shell.respond_to?(:task_manager)

        if ["all", "tasks"].include?(target) && task_mgr
          tasks = task_mgr.list
          lines << "\n[Background Tasks (#{tasks.size} Tracked)]:"
          if tasks.empty?
            lines << "  (none)"
          else
            tasks.each do |t|
              dur = t.running? ? "up #{t.uptime.round(1)}s" : "#{t.status} (exit #{t.exit_code})"
              lines << "  • [#{t.id}] #{t.status.to_s.upcase} (PID #{t.pid}, #{dur}): #{t.command}"
            end
          end
        end

        lines.join("\n")
      end
    end

    class ProvideServiceTool < BaseTool
      def initialize(runtime_manager = nil)
        super(
          name: "provide_service",
          aliases: ["register_service", "add_service"],
          description: "Provide a runtime service/coeffect into the root context, " \
                       "triggering reactive state transitions (Pending -> Active) for dependent fibers",
          risk: :execute,
          params_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Service/coeffect name (e.g. 'database', 'lsp_client', 'mock_api')" },
              value: { type: "string", description: "Service description or initialization payload" }
            },
            required: ["name"]
          }
        )
        @runtime_manager = runtime_manager
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.downcase
        val = args["value"] || args[:value] || true
        return ToolOutput.error("Service name cannot be empty.") if name.empty?
        return ToolOutput.error("Runtime manager is not available.") unless @runtime_manager

        @runtime_manager.provide(name, val)
        active_count = @runtime_manager.active_fibers.size
        pending_count = @runtime_manager.pending_fibers.size

        "Service '#{name}' provided to runtime context. Reconciled fibers: #{active_count} Active, #{pending_count} Pending."
      end
    end
  end
end
