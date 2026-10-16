# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentTypeRegistry < Minitest::Test
  def setup
    @registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    @root_ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @root_ctx&.dispose unless @root_ctx&.disposed?
  end

  # =========================================================================
  # 1. Built-in archetype separation and protection
  # =========================================================================

  def test_registers_built_in_types_separately_from_dynamic_path
    assert @registry.builtin?("research")
    assert @registry.builtin?("coder")
    assert @registry.builtin?("self")
    assert @registry.builtin?("vakanuvis")
    assert @registry.builtin?("pruner")
    refute @registry.dynamic?("research")
    refute @registry.builtin?("custom_agent")

    builtins = @registry.builtins
    assert_equal 5, builtins.size
    assert_equal %w[coder pruner research self vakanuvis], builtins.map(&:name).sort
  end

  def test_prevents_overriding_built_in_archetype_by_default
    err = assert_raises(ArgumentError) do
      @registry.define_custom(
        name: "research",
        description: "Modified research",
        system_prompt: "You explore everything."
      )
    end
    assert_includes err.message, "Cannot define archetype 'research' because it would override a built-in archetype"
    assert_includes err.message, "allow_override: true"
  end

  def test_explicitly_overrides_built_in_and_restores_it_when_context_is_disposed
    orig_research = @registry.get("research")
    child_ctx = @root_ctx.extend

    handle = @registry.define_custom(
      name: "research",
      description: "Custom research override",
      system_prompt: "You are an enhanced researcher.",
      context: child_ctx,
      allow_override: true
    )

    assert_equal "research", handle.name
    assert_equal "Custom research override", @registry.get("research").description
    assert @registry.builtin?("research")
    assert @registry.dynamic?("research")

    # When child context is disposed, the original built-in is restored
    child_ctx.dispose

    restored = @registry.get("research")
    assert_equal orig_research.description, restored.description
    refute @registry.dynamic?("research")
  end

  # =========================================================================
  # 2. Dynamic registration lifecycle and context disposal
  # =========================================================================

  def test_associates_dynamic_registration_with_context_and_removes_on_disposal
    ctx = @root_ctx.extend

    handle = @registry.define_custom(
      name: "analyst",
      description: "Data analysis subagent",
      system_prompt: "Analyze tabular data.",
      enable_write_tools: false,
      context: ctx
    )

    assert_equal 1, handle.revision
    assert_equal "analyst", handle.name
    assert @registry.dynamic?("analyst")
    assert_equal handle.type_def, @registry.get("analyst")
    assert_includes @registry.dynamics.map(&:name), "analyst"
    assert_includes @registry.list.map(&:name), "analyst"

    ctx.dispose

    assert_nil @registry.get("analyst")
    refute @registry.dynamic?("analyst")
    refute_includes @registry.list.map(&:name), "analyst"
  end

  def test_refuses_registration_in_an_already_disposed_context
    ctx = @root_ctx.extend
    ctx.dispose

    err = assert_raises(ArgumentError) do
      @registry.define_custom(
        name: "post_mortem",
        description: "Should fail fast",
        system_prompt: "Fail fast.",
        context: ctx
      )
    end
    assert_includes err.message, "Cannot define archetype 'post_mortem' in a disposed context"
  end

  # =========================================================================
  # 3. Dynamic replacement behavior and LIFO restoration
  # =========================================================================

  def test_refuses_re_registration_of_dynamic_name_without_replace_permission
    ctx1 = @root_ctx.extend
    @registry.define_custom(
      name: "tester",
      description: "Original tester",
      system_prompt: "Run tests.",
      context: ctx1
    )

    err = assert_raises(ArgumentError) do
      @registry.define_custom(
        name: "tester",
        description: "Duplicate tester without replace flag",
        system_prompt: "Run different tests.",
        context: ctx1
      )
    end
    assert_includes err.message, "Cannot define archetype 'tester' because it is already registered"
    assert_includes err.message, "replace: true"
  end

  def test_replaces_dynamic_archetype_with_explicit_flag_and_restores_prior_profile_on_disposal
    ctx1 = @root_ctx.extend
    ctx2 = ctx1.extend

    handle1 = @registry.define_custom(
      name: "worker",
      description: "Worker v1",
      system_prompt: "Do work v1.",
      context: ctx1
    )
    assert_equal 1, handle1.revision
    assert_equal "Worker v1", @registry.get("worker").description

    handle2 = @registry.define_custom(
      name: "worker",
      description: "Worker v2",
      system_prompt: "Do work v2.",
      context: ctx2,
      replace: true
    )
    assert_equal 2, handle2.revision
    assert_equal "Worker v2", @registry.get("worker").description
    assert_equal 2, @registry.revision_for("worker")

    # Disposing child context ctx2 unwinds handle2 and restores handle1
    ctx2.dispose

    assert_equal "Worker v1", @registry.get("worker").description
    assert_equal 1, @registry.revision_for("worker")

    # Disposing parent context ctx1 unwinds handle1 completely
    ctx1.dispose

    assert_nil @registry.get("worker")
    refute @registry.dynamic?("worker")
  end

  # =========================================================================
  # 4. Stale cleanup safety (out-of-order disposal)
  # =========================================================================

  def test_stale_cleanup_does_not_remove_or_overwrite_newer_registration
    ctx1 = @root_ctx.extend
    ctx2 = @root_ctx.extend

    handle1 = @registry.define_custom(
      name: "logger",
      description: "Logger v1",
      system_prompt: "Log v1.",
      context: ctx1
    )

    handle2 = @registry.define_custom(
      name: "logger",
      description: "Logger v2",
      system_prompt: "Log v2.",
      context: ctx2,
      replace: true
    )
    assert_equal "Logger v2", @registry.get("logger").description

    # Stale cleanup: ctx1 is disposed BEFORE ctx2
    ctx1.dispose

    # The newer registration in ctx2 MUST remain intact and untouched
    assert_equal "Logger v2", @registry.get("logger").description
    assert_equal 2, @registry.revision_for("logger")
    assert handle2.active?
    refute handle1.active?

    # Disposing ctx2 later cleans up logger entirely (does not resurrect v1)
    ctx2.dispose

    assert_nil @registry.get("logger")
    refute @registry.dynamic?("logger")
  end

  # =========================================================================
  # 5. Idempotent cleanup and repeated disposal
  # =========================================================================

  def test_repeated_undo_and_disposal_are_idempotent
    ctx = @root_ctx.extend
    handle = @registry.define_custom(
      name: "idempotent_test",
      description: "desc",
      system_prompt: "prompt",
      context: ctx
    )

    assert handle.active?
    assert handle.undo, "first undo succeeds"
    refute handle.active?
    refute handle.undo, "second undo is a no-op returning false"
    assert_nil @registry.get("idempotent_test")

    # Context disposal afterwards is safely idempotent
    assert_silent { ctx.dispose }
    assert_silent { ctx.dispose }
  end

  # =========================================================================
  # 6. RegistrationHandle interface
  # =========================================================================

  def test_handle_delegates_to_type_definition_and_exposes_revision_metadata
    ctx = @root_ctx.extend
    handle = @registry.define_custom(
      name: "proxy_test",
      description: "Proxy archetype description",
      system_prompt: "Proxy prompt",
      enable_write_tools: true,
      enable_subagent_tools: false,
      context: ctx
    )

    assert_kind_of Rubik::Orchestrator::Subagent::TypeDefinition, handle
    assert_kind_of Rubik::Orchestrator::Subagent::RegistrationHandle, handle
    assert_equal "proxy_test", handle.name
    assert_equal "Proxy archetype description", handle.description
    assert_equal "Proxy prompt", handle.system_prompt
    assert handle.enable_write_tools
    refute handle.enable_subagent_tools
    assert handle.custom_prompt
    assert_equal 1, handle.revision
    assert_equal ctx, handle.context
    assert_equal handle, handle.type_def.handle
    assert_equal 1, handle.type_def.revision
  end

  # =========================================================================
  # 7. DefineSubagentTool integration
  # =========================================================================

  def test_define_subagent_tool_respects_runtime_context_and_options
    sup = Struct.new(:type_registry, :root_context).new(@registry, @root_ctx)
    turn_ctx = @root_ctx.extend
    tool = Rubik::Tools::DefineSubagentTool.new(supervisor: sup, runtime_context: turn_ctx)

    res = tool.execute(
      name: "tool_defined",
      description: "Built via tool",
      system_prompt: "Run from tool"
    )
    refute res.respond_to?(:error?) && res.error?
    assert_includes res.to_s, "Subagent archetype 'tool_defined' successfully defined"
    assert @registry.get("tool_defined")

    # Attempting to overwrite without replace returns error ToolOutput
    res_err = tool.execute(
      name: "tool_defined",
      description: "Duplicate",
      system_prompt: "Duplicate prompt"
    )
    assert res_err.respond_to?(:error?) && res_err.error?
    assert_includes res_err.to_s, "already registered"

    # With replace: true, succeeds
    res_replace = tool.execute(
      name: "tool_defined",
      description: "Replaced via tool",
      system_prompt: "Replaced prompt",
      replace: true
    )
    refute res_replace.respond_to?(:error?) && res_replace.error?
    assert_equal "Replaced via tool", @registry.get("tool_defined").description

    # Disposing the turn context cleans it up
    turn_ctx.dispose
    assert_nil @registry.get("tool_defined")
  end
end
