# frozen_string_literal: true

require "monitor"
require_relative "base"
require_relative "../coeffects"

module Rubik
  module Tools
    class Registry
      def initialize(coeffect_ctx: nil)
        @tools = {}
        @aliases = {}
        @origins = {}
        @coeffect_ctx = coeffect_ctx
        @monitor = Monitor.new
      end

      # origin labels where a tool came from (:builtin, :overlay, :mcp,
      # :synthesis). The synthesizer uses it to refuse shadowing built-ins
      # while still allowing hot-updates of non-builtin tools.
      def register(tool_instance, aliases: [], origin: :builtin)
        @monitor.synchronize do
          @tools[tool_instance.name] = tool_instance
          @origins[tool_instance.name] = origin
          all_aliases = (tool_instance.respond_to?(:aliases) ? Array(tool_instance.aliases) : []) + Array(aliases)
          all_aliases.each do |al|
            @aliases[al.to_s.downcase] = tool_instance.name
          end
          tool_instance
        end
      end

      def unregister(name)
        @monitor.synchronize do
          canonical_name = @tools.key?(name.to_s) ? name.to_s : @aliases[name.to_s.downcase]
          removed_tool = @tools.delete(canonical_name) if canonical_name
          @origins.delete(canonical_name) if canonical_name
          @aliases.delete_if { |_k, v| v == canonical_name || v == name.to_s }
          @aliases.delete(name.to_s.downcase)
          removed_tool
        end
      end

      # Atomic hot-swap of an existing tool with a new tool instance.
      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # meaning the calling thread can safely enter unregister and register without deadlock.
      def swap(name, new_tool, origin: :builtin)
        @monitor.synchronize do
          unregister(name)
          register(new_tool, origin: origin) if new_tool
        end
      end

      def get(tool_name)
        @monitor.synchronize do
          @tools[tool_name.to_s] || begin
            canonical = @aliases[tool_name.to_s.downcase]
            canonical ? @tools[canonical] : nil
          end
        end
      end

      # Registration origin of the tool resolved by name (canonical or alias),
      # or nil when no such tool is registered.
      def origin(name)
        @monitor.synchronize do
          canonical = @tools.key?(name.to_s) ? name.to_s : @aliases[name.to_s.downcase]
          canonical ? @origins[canonical] : nil
        end
      end

      def list
        @monitor.synchronize do
          @tools.values.dup
        end
      end

      # Schemas of tools whose declared coeffects (REQUIRES) are currently
      # satisfied — the toolbelt-side of the fiber state machine (AGENTS.md
      # §2): a tool missing its coeffects sits PENDING (hidden from the LLM)
      # and activates reactively when a provider supplies the service.
      # Called per agent step, so the filter re-evaluates live. Tools remain
      # invocable via Registry#get for graceful self-correction errors.
      def schemas
        @monitor.synchronize do
          @tools.values.select { |t| coeffects_satisfied?(t) }.map(&:to_h)
        end
      end

      def aliases_map
        @monitor.synchronize do
          @aliases.dup
        end
      end

      def self.build_default(
        buffer_manager:, context_index: nil, ast_graph: nil, adapter_registry: nil, guard: nil,
        sandbox_runner: nil, shell: nil, overlay_storage: nil, runtime_manager: nil, lsp_manager: nil,
        task_manager: nil, subagent_supervisor: nil, config: nil, root_dir: Dir.pwd
      )
        ctx = runtime_manager&.context
        registry = new(coeffect_ctx: ctx.respond_to?(:satisfied?) ? ctx : nil)
        native_switch = config || shell&.config
        effective_context = context_index || Rubik::Coeffects.get(ctx, Rubik::Coeffects::CONTEXT_INDEX) ||
                            Rubik::Context::Index.new(root_dir: root_dir, native: native_switch&.fetch("tools.native"))
        effective_adapter_registry = adapter_registry || Rubik::Adapter::Registry.new
        effective_task_manager = task_manager || Rubik::Coeffects.get(ctx, Rubik::Coeffects::TASK_MANAGER)
        # House triple chain (cf. effective_task_manager above): explicit
        # kwarg, then the runtime coeffect (wire_runtime_context provides the
        # shared session guard), then a fresh zero-policy Guard so standalone
        # registry constructions stay fail-closed.
        effective_guard = guard || Rubik::Coeffects.get(ctx, Rubik::Coeffects::GUARD) || Rubik::Security::Guard.new
        registry.register(ReadFileTool.new(buffer_manager))
        registry.register(ReplaceFileContentTool.new(buffer_manager))
        registry.register(WriteFileTool.new(buffer_manager))
        registry.register(ListFilesTool.new(effective_context, root_dir: root_dir, runtime_context: ctx))
        registry.register(GrepSearchTool.new(buffer_manager, effective_context, root_dir: root_dir, runtime_context: ctx, config: native_switch))
        effective_ast = ast_graph || Rubik::Coeffects.get(ctx, Rubik::Coeffects::AST_GRAPH) || Rubik::AST::Graph.new
        registry.register(SearchSymbolsTool.new(effective_ast, runtime_context: ctx))
        registry.register(GetOutlineTool.new(effective_ast, runtime_context: ctx))
        registry.register(FindReferencesTool.new(effective_ast, runtime_context: ctx))
        registry.register(GetSymbolTool.new(effective_ast, runtime_context: ctx))
        registry.register(LSPDiagnosticsTool.new(lsp_manager, buffer_manager: buffer_manager))
        registry.register(LSPHoverTool.new(lsp_manager, buffer_manager: buffer_manager))
        registry.register(LSPDefinitionTool.new(lsp_manager, buffer_manager: buffer_manager))
        registry.register(RunTestsTool.new(effective_adapter_registry, context_index, root_dir: root_dir,
                                                                                      config: config || shell&.config, guard: effective_guard))
        registry.register(RunCommandTool.new(
                            guard: effective_guard,
                            runner: sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: root_dir, guard: effective_guard),
                            root_dir: root_dir,
                            task_manager: effective_task_manager,
                            runtime_context: ctx
                          ))
        registry.register(ManageTaskTool.new(task_manager: effective_task_manager, guard: effective_guard, runtime_context: ctx))
        registry.register(ExecReplCommandTool.new(shell))
        registry.register(SynthesizeCommandTool.new(shell, overlay_storage, effective_guard, runtime_manager: runtime_manager))
        registry.register(SynthesizeToolTool.new(registry, overlay_storage, effective_guard, runtime_manager: runtime_manager))
        registry.register(UnsynthesizeTool.new(shell, registry, overlay_storage, runtime_manager: runtime_manager))
        registry.register(InspectRuntimeTool.new(runtime_manager, registry, shell))
        registry.register(ProvideServiceTool.new(runtime_manager))
        registry.register(RepairRuntimeTool.new(
                            runtime_manager: runtime_manager,
                            lsp_manager: lsp_manager,
                            adapter_registry: effective_adapter_registry,
                            overlay_storage: overlay_storage,
                            config: config || shell&.config,
                            root_dir: root_dir,
                            guard: effective_guard
                          ))
        registry.register(ApplyBufferTool.new(buffer_manager, shell))
        registry.register(AskQuestionTool.new(shell: shell))
        effective_subagent_supervisor = subagent_supervisor || Rubik::Coeffects.get(ctx, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
        registry.register(InvokeSubagentTool.new(supervisor: effective_subagent_supervisor, runtime_context: ctx))
        registry.register(ManageSubagentsTool.new(supervisor: effective_subagent_supervisor, runtime_context: ctx))
        registry.register(SendMessageTool.new(supervisor: effective_subagent_supervisor, runtime_context: ctx))
        registry.register(DefineSubagentTool.new(supervisor: effective_subagent_supervisor, runtime_context: ctx))
        registry.register(FinishTool.new)

        overlay_storage&.load_tools(registry)
        # Inverse-by-construction (AGENTS.md §1.A): one monoidal inverse for
        # the whole registry — context teardown unregisters every tool in
        # strict LIFO order together with the rest of the session effects.
        ctx&.register_disposable { registry.list.each { |t| registry.unregister(t.name) } } if ctx.respond_to?(:register_disposable)
        registry
      end

      private

      # A tool is satisfied when it declares no REQUIRES, when no coeffect
      # context is wired (plain registries keep advertising everything), or
      # when the context chain satisfies every declared dependency.
      def coeffects_satisfied?(tool)
        return true unless tool.class.const_defined?(:REQUIRES)

        deps = tool.class.const_get(:REQUIRES)
        return true if deps.nil? || deps.empty?
        return true unless @coeffect_ctx.respond_to?(:satisfied?)

        @coeffect_ctx.satisfied?(deps)
      end
    end
  end
end
