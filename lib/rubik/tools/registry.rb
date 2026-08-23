# frozen_string_literal: true

require_relative "base"

module Rubik
  module Tools
    class Registry
      def initialize
        @tools = {}
      end

      def register(tool_instance)
        @tools[tool_instance.name] = tool_instance
      end

      def get(tool_name)
        @tools[tool_name]
      end

      def list
        @tools.values
      end

      def schemas
        @tools.values.map(&:to_h)
      end

      def self.build_default(buffer_manager:, context_index: nil, ast_graph: nil, adapter_registry: nil, guard: nil, sandbox_runner: nil, shell: nil, overlay_storage: nil, runtime_manager: nil, root_dir: Dir.pwd)
        registry = new
        registry.register(ReadFileTool.new(buffer_manager))
        registry.register(WriteFileTool.new(buffer_manager))
        registry.register(ListFilesTool.new(context_index || Rubik::Context::Index.new(root_dir: root_dir), root_dir: root_dir))
        registry.register(SearchSymbolsTool.new(ast_graph || Rubik::AST::Graph.new))
        registry.register(RunTestsTool.new(adapter_registry || Rubik::Adapter::Registry.new, context_index, root_dir: root_dir))
        registry.register(RunCommandTool.new(guard: guard || Rubik::Security::Guard.new, runner: sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: root_dir), root_dir: root_dir))
        registry.register(ExecReplCommandTool.new(shell))
        registry.register(SynthesizeCommandTool.new(shell, overlay_storage, guard))
        registry.register(SynthesizeToolTool.new(registry, overlay_storage, guard))
        registry.register(InspectRuntimeTool.new(runtime_manager, registry, shell))
        registry.register(ProvideServiceTool.new(runtime_manager))
        registry.register(ApplyBufferTool.new(buffer_manager))
        registry.register(FinishTool.new)

        overlay_storage&.load_tools(registry)
        registry
      end
    end
  end
end
