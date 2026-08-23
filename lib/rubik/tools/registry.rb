# frozen_string_literal: true

require "monitor"
require_relative "base"

module Rubik
  module Tools
    class Registry
      def initialize
        @tools = {}
        @monitor = Monitor.new
      end

      def register(tool_instance)
        @monitor.synchronize do
          @tools[tool_instance.name] = tool_instance
        end
      end

      def unregister(name)
        @monitor.synchronize do
          @tools.delete(name.to_s)
        end
      end

      def swap(name, new_tool)
        @monitor.synchronize do
          @tools.delete(name.to_s)
          @tools[new_tool.name] = new_tool if new_tool
        end
      end

      def get(tool_name)
        @monitor.synchronize do
          @tools[tool_name.to_s]
        end
      end

      def list
        @monitor.synchronize do
          @tools.values.dup
        end
      end

      def schemas
        @monitor.synchronize do
          @tools.values.map(&:to_h)
        end
      end

      def self.build_default(buffer_manager:, context_index: nil, ast_graph: nil, adapter_registry: nil, guard: nil, sandbox_runner: nil, shell: nil, overlay_storage: nil, runtime_manager: nil, lsp_manager: nil, root_dir: Dir.pwd)
        registry = new
        registry.register(ReadFileTool.new(buffer_manager))
        registry.register(WriteFileTool.new(buffer_manager))
        registry.register(ListFilesTool.new(context_index || Rubik::Context::Index.new(root_dir: root_dir), root_dir: root_dir))
        effective_ast = ast_graph || Rubik::AST::Graph.new
        registry.register(SearchSymbolsTool.new(effective_ast))
        registry.register(GetOutlineTool.new(effective_ast))
        registry.register(FindReferencesTool.new(effective_ast))
        registry.register(GetSymbolTool.new(effective_ast))
        registry.register(LSPDiagnosticsTool.new(lsp_manager))
        registry.register(LSPHoverTool.new(lsp_manager))
        registry.register(LSPDefinitionTool.new(lsp_manager))
        registry.register(RunTestsTool.new(adapter_registry || Rubik::Adapter::Registry.new, context_index, root_dir: root_dir))
        registry.register(RunCommandTool.new(guard: guard || Rubik::Security::Guard.new, runner: sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: root_dir), root_dir: root_dir))
        registry.register(ExecReplCommandTool.new(shell))
        registry.register(SynthesizeCommandTool.new(shell, overlay_storage, guard, runtime_manager: runtime_manager))
        registry.register(SynthesizeToolTool.new(registry, overlay_storage, guard, runtime_manager: runtime_manager))
        registry.register(InspectRuntimeTool.new(runtime_manager, registry, shell))
        registry.register(ProvideServiceTool.new(runtime_manager))
        registry.register(ApplyBufferTool.new(buffer_manager, shell))
        registry.register(FinishTool.new)

        overlay_storage&.load_tools(registry)
        registry
      end
    end
  end
end
