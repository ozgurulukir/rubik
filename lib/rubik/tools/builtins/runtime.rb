# frozen_string_literal: true

require_relative "../base"

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
              target: { type: "string", enum: ["all", "fibers", "services", "tools", "commands"], description: "Component to inspect (default: all)" }
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
          services = root_ctx.instance_variable_get(:@services) || {}
          disposables = root_ctx.instance_variable_get(:@disposables) || []
          lines << "\n[Services / Coeffects Active (#{services.size})]:"
          services.each { |k, v| lines << "  • #{k.to_s.ljust(12)} -> #{v.class}" }
          lines << "  (LIFO Accumulator Depth: #{disposables.size} inverse disposables)"
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
        return "Service name cannot be empty" if name.empty?
        return "Runtime manager is not available" unless @runtime_manager

        @runtime_manager.provide(name, val)
        active_count = @runtime_manager.active_fibers.size
        pending_count = @runtime_manager.pending_fibers.size

        "Service '#{name}' provided to runtime context. Reconciled fibers: #{active_count} Active, #{pending_count} Pending."
      end
    end
  end
end
