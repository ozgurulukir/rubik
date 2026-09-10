# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSpatiotemporalRuntimeInvariants < Minitest::Test
  class DummyTool < Rubik::Tools::BaseTool
    def initialize(name = "dummy_tool")
      super(
        name: name,
        description: "A dummy tool for invariant testing",
        risk: :read,
        params_schema: { type: "object", properties: {} }
      )
    end

    def execute(_args = {})
      "dummy_result"
    end
  end

  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      super()
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text)
    end
  end

  def setup
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(output: @output)
    @registry = Rubik::Tools::Registry.new
  end

  def teardown
    @shell&.stop
  end

  # 1. ToolRegistry unregister & swap & thread-safety
  def test_tool_registry_unregister_and_swap
    tool1 = DummyTool.new("tool_v1")
    tool2 = DummyTool.new("tool_v2")

    @registry.register(tool1)
    assert_equal tool1, @registry.get("tool_v1")
    assert_includes @registry.list, tool1

    # Unregister
    removed = @registry.unregister("tool_v1")
    assert_equal tool1, removed
    assert_nil @registry.get("tool_v1")
    refute_includes @registry.list, tool1

    # Swap
    @registry.register(tool1)
    @registry.swap("tool_v1", tool2)
    assert_nil @registry.get("tool_v1")
    assert_equal tool2, @registry.get("tool_v2")
    assert_includes @registry.list, tool2
    refute_includes @registry.list, tool1
  end

  def test_tool_registry_thread_safety
    registry = Rubik::Tools::Registry.new
    threads = []
    thread_count = 10
    iterations = 100

    thread_count.times do |t_idx|
      threads << Thread.new do
        iterations.times do |i|
          name = "tool_t#{t_idx}_#{i}"
          tool = DummyTool.new(name)
          registry.register(tool)
          _ = registry.get(name)
          _ = registry.list
          _ = registry.schemas
          replacement = DummyTool.new("#{name}_swapped")
          registry.swap(name, replacement)
          registry.unregister("#{name}_swapped")
        end
      end
    end

    threads.each(&:join)
    # If thread safety had race conditions, deadlocks or Monitor errors would occur
    assert_empty registry.list
  end

  # 1b. Toolbelt coeffect gating: PENDING (hidden from schemas) -> ACTIVE reactively
  class GatedTool < DummyTool
    REQUIRES = [Rubik::Coeffects::AST_GRAPH].freeze
  end

  def test_toolbelt_coeffect_gating_pending_to_active
    ctx = Rubik::Runtime::Context.new
    registry = Rubik::Tools::Registry.new(coeffect_ctx: ctx)

    registry.register(GatedTool.new("gated_tool"))
    registry.register(DummyTool.new("free_tool"))

    # PENDING: coeffect missing -> hidden from schemas, but still invocable
    refute_includes registry.schemas.map { |s| s[:name] }, "gated_tool"
    assert_includes registry.schemas.map { |s| s[:name] }, "free_tool"
    assert registry.get("gated_tool"), "Pending tool must stay invocable for graceful self-correction"

    # ACTIVATING: provider supplies the coeffect -> tool is advertised again
    ctx.provide(Rubik::Coeffects::AST_GRAPH, Rubik::AST::Graph.new)
    assert_includes registry.schemas.map { |s| s[:name] }, "gated_tool"
  end

  # 2. Shell#unregister_command
  def test_shell_unregister_command
    @shell.register_command("custom_op", description: "Custom Operation") { "result" }
    assert @shell.commands.key?("custom_op")

    # Unregister with string without !
    @shell.unregister_command("custom_op")
    refute @shell.commands.key?("custom_op")

    # Unregister with ! prefix and case variation
    @shell.register_command("another_op", description: "Another Operation") { "result" }
    assert @shell.commands.key?("another_op")
    @shell.unregister_command("!ANOTHER_OP")
    refute @shell.commands.key?("another_op")
  end

  # 3. Core service coeffects resolution
  def test_core_service_coeffects_resolution
    ctx = @shell.runtime_manager.context

    # Canonical (long-form) keys only — shell provides one key per subsystem.
    assert_equal @shell.buffer_manager, ctx.require(:buffer_manager)
    assert_equal @shell.snapshot_store, ctx.require(:snapshot_store)
    assert_equal @shell.lsp_manager, ctx.require(:lsp_manager)

    assert_equal @shell.ast_graph, ctx.require(:ast_graph)

    assert_equal @shell.guard, ctx.require(:guard)
    assert_equal @shell.guard, ctx.require("guard")

    assert_equal @shell.sandbox_runner, ctx.require(:sandbox)
    assert_equal @shell.sandbox_runner, ctx.require("sandbox")

    assert_equal @shell.adapter_registry, ctx.require(:adapter_registry)

    assert_equal @shell.event_bus, ctx.require(:events)
    assert_equal @shell.event_bus, ctx.require("events")

    assert_equal @shell.config, ctx.require(:config)
    assert_equal @shell.config, ctx.require("config")

    assert_equal @shell.context_index, ctx.require(:context_index)

    # Services are published under canonical keys only (no duplicate alias
    # provides); legacy short-form reads still resolve to the canonical
    # service via the Runtime::Context alias bridge (plugin DSL contract).
    ["buffer", "snapshot", "lsp", "ast", "index", "adapters"].each do |alias_key|
      refute ctx.services.key?(alias_key), "alias '#{alias_key}' must not be stored literally"
    end
    assert_equal @shell.buffer_manager, ctx.require(:buffer)
    assert_equal @shell.snapshot_store, ctx.require(:snapshot)
    assert_equal @shell.lsp_manager, ctx.require(:lsp)
    assert_equal @shell.ast_graph, ctx.require(:ast)
    assert_equal @shell.context_index, ctx.require(:index)
    assert_equal @shell.adapter_registry, ctx.require(:adapters)
    assert_equal @shell.buffer_manager, Rubik::Coeffects.get(ctx, Rubik::Coeffects::BUFFER_MANAGER)
    assert_equal @shell.lsp_manager, Rubik::Coeffects.get(ctx, Rubik::Coeffects::LSP_MANAGER)

    all_coeffects = [:buffer_manager, :snapshot_store, :lsp_manager, :ast_graph, :guard, :sandbox, :adapter_registry, :events, :config, :context_index]
    assert ctx.satisfied?(all_coeffects)
  end

  # 4. SynthesizeToolTool inverse unwinding upon context disposal
  def test_synthesize_tool_inverse_unwinding
    tool_reg = Rubik::Tools::Registry.new
    root_ctx = Rubik::Runtime::Context.new
    scoped_ctx = root_ctx.extend
    mgr = Rubik::Runtime::Manager.new(scoped_ctx)

    synth_tool = Rubik::Tools::SynthesizeToolTool.new(tool_reg, runtime_manager: mgr)

    code = "->(args) { 'fibers_rock' }"
    res = synth_tool.execute(name: "dynamic_math", description: "Compute math", code: code)
    assert_includes res, "Successfully synthesized and registered"

    # Tool is active in registry
    assert tool_reg.get("dynamic_math")
    assert_equal "fibers_rock", tool_reg.get("dynamic_math").execute

    # Context disposal triggers LIFO unwinding
    scoped_ctx.dispose
    assert_nil tool_reg.get("dynamic_math"), "Synthesized tool must be automatically unregistered upon context disposal"
  end

  # 5. SynthesizeCommandTool inverse unwinding upon context disposal
  def test_synthesize_command_inverse_unwinding
    root_ctx = Rubik::Runtime::Context.new
    scoped_ctx = root_ctx.extend
    mgr = Rubik::Runtime::Manager.new(scoped_ctx)

    synth_cmd = Rubik::Tools::SynthesizeCommandTool.new(@shell, runtime_manager: mgr)

    code = "->(args, out, shell) { out.puts 'hello dynamic' }"
    res = synth_cmd.execute(name: "dynamic_greeting", description: "Greets dynamically", code: code)
    assert_includes res, "Successfully synthesized and registered !dynamic_greeting"

    # Command is registered in Shell
    assert @shell.commands.key?("dynamic_greeting")

    # Context disposal triggers LIFO unwinding
    scoped_ctx.dispose
    refute @shell.commands.key?("dynamic_greeting"), "Synthesized command must be automatically unregistered upon context disposal"
  end

  # 5b. Hot-updated custom command is RESTORED (not deleted) upon disposal (AGENTS.md §1.A)
  def test_synthesize_command_hot_update_restores_previous_on_dispose
    @shell.register_command("deploy", description: "old deploy", custom: true) { |_args| "OLD HANDLER" }

    root_ctx = Rubik::Runtime::Context.new
    scoped_ctx = root_ctx.extend
    mgr = Rubik::Runtime::Manager.new(scoped_ctx)
    synth_cmd = Rubik::Tools::SynthesizeCommandTool.new(@shell, runtime_manager: mgr)

    res = synth_cmd.execute(name: "deploy", description: "new deploy", code: "->(args) { 'NEW HANDLER' }")
    assert_includes res, "Successfully synthesized and registered !deploy"
    assert_equal "new deploy [session]", @shell.commands["deploy"][:description]

    scoped_ctx.dispose
    assert @shell.commands.key?("deploy"), "Previous custom command must be restored on disposal, not deleted"
    assert_equal "old deploy", @shell.commands["deploy"][:description]
    assert_equal "OLD HANDLER", @shell.commands["deploy"][:handler].call("x")
  end

  # 6. REPL !runtime, !fibers, !services commands output
  def test_runtime_repl_commands_output
    # Register pending and active fibers to verify diagnostics
    @shell.runtime_manager.register_component("active_fiber", inject: ["buffer_manager", "lsp_manager"]) do |_ctx, _cfg|
      # Active because buffer_manager & lsp_manager are provided (canonical keys)
    end

    @shell.runtime_manager.register_component("pending_fiber", inject: ["non_existent_service"]) do |_ctx, _cfg|
      # Pending
    end

    # Test !runtime
    @output.reopen
    @shell.execute_input("!runtime")
    out = @output.string
    assert_includes out, "Rubik Spatiotemporal Runtime Diagnostics"
    assert_includes out, "Services / Coeffects Active"
    assert_includes out, "buffer_manager"
    assert_includes out, "lsp_manager"
    assert_includes out, "ACTIVE : active_fiber"
    assert_includes out, "PENDING: pending_fiber"
    assert_includes out, "waiting on: non_existent_service"
    assert_includes out, "LIFO Accumulator Depth"

    # Test !fibers
    @output.reopen
    @shell.execute_input("!fibers")
    out_fibers = @output.string
    assert_includes out_fibers, "ACTIVE : active_fiber"
    assert_includes out_fibers, "PENDING: pending_fiber"

    # Test !services
    @output.reopen
    @shell.execute_input("!services")
    out_services = @output.string
    assert_includes out_services, "buffer_manager"
    assert_includes out_services, "snapshot_store"
    assert_includes out_services, "lsp_manager"
    assert_includes out_services, "ast_graph"
  end

  # 7. Orchestrator Loop scoped sub-context lifecycle
  def test_orchestrator_loop_scoped_subcontext_lifecycle
    @shell.runtime_manager
    tool_reg = @shell.build_tool_registry

    provider = MockScriptProvider.new([
                                        '{"tool": "finish", "args": { "message": "done" }}'
                                      ])

    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: tool_reg,
      shell: @shell
    )

    res = orchestrator.run("Test task")
    assert res[:ok]
    assert_equal "done", res[:output]

    # Verify loop_context was created and subsequently disposed
    loop_ctx = orchestrator.loop_context
    assert loop_ctx, "Loop should have initialized a loop_context"
    assert loop_ctx.disposed?, "Loop sub-context must be disposed after execution completes"
  end
end
