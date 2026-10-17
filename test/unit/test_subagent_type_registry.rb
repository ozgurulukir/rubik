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
    assert_equal ["coder", "pruner", "research", "self", "vakanuvis"], builtins.map(&:name).sort
  end

  def test_refuses_reserved_builtin_overrides_even_when_explicitly_requested
    ["research", "coder", "self", "vakanuvis", "pruner"].each do |name|
      original = @registry.get(name)
      err = assert_raises(ArgumentError) do
        @registry.define_custom(
          name: name,
          description: "Attempted #{name} override",
          system_prompt: "This must not replace a system role.",
          context: @root_ctx,
          allow_override: true
        )
      end

      assert_includes err.message, "built-in system archetypes are reserved"
      assert_same original, @registry.get(name)
      refute @registry.dynamic?(name)
    end
  end

  def test_dynamic_register_cannot_bypass_reserved_names_and_normalizes_names
    analyst = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "  Analyst ", description: "A test profile", system_prompt: "Analyze.",
      custom_prompt: false, context: @root_ctx
    )
    handle = @registry.register(analyst)

    assert_equal "analyst", handle.name
    assert_same analyst, @registry.get("ANALYST")
    assert analyst.custom_prompt

    reserved = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "RESEARCH", description: "Override", system_prompt: "Replace Maestro's role.",
      custom_prompt: true, context: @root_ctx
    )
    err = assert_raises(ArgumentError) { @registry.register(reserved) }

    assert_includes err.message, "built-in system archetypes are reserved"
    assert @registry.get("research").system_prompt.include?("Codebase Research Subagent")
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
    missing_owner = assert_raises(ArgumentError) do
      @registry.define_custom(
        name: "unowned",
        description: "Must not outlive a context",
        system_prompt: "No implicit process lifetime."
      )
    end
    assert_includes missing_owner.message, "require an active owner context"
    assert_nil @registry.get("unowned")

    unowned_type = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "unowned_direct", description: "Must not bypass owner validation",
      system_prompt: "No ambient registration.", custom_prompt: true
    )
    direct_error = assert_raises(ArgumentError) { @registry.register(unowned_type) }
    assert_includes direct_error.message, "require an active owner context"
    assert_equal "unowned_direct", unowned_type.name
    assert_nil @registry.get("unowned_direct")

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
    assert_includes err.message, "disposed context"
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

  def test_concurrent_duplicate_registration_requires_explicit_replacement
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ready << true
        start.pop
        @registry.define_custom(
          name: "parallel_worker",
          description: "Worker #{index}",
          system_prompt: "Run worker #{index}.",
          context: @root_ctx
        )
        :registered
      rescue ArgumentError
        :rejected
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    outcomes = threads.map(&:value)

    assert_equal 1, outcomes.count(:registered)
    assert_equal 1, outcomes.count(:rejected)
    assert @registry.get("parallel_worker")
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

  def test_replacing_same_type_definition_preserves_previous_revision_on_disposal
    ctx1 = @root_ctx.extend
    ctx2 = @root_ctx.extend
    type_def = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "shared_worker", description: "Shared worker", system_prompt: "Do work.",
      custom_prompt: true, context: ctx1
    )

    handle1 = @registry.register(type_def, context: ctx1)
    handle2 = @registry.register(type_def, context: ctx2, replace: true)

    refute_same handle1.type_def, handle2.type_def
    assert_same type_def, handle1.type_def
    assert_same handle2.type_def, @registry.get("shared_worker")

    ctx2.dispose

    assert_same type_def, @registry.get("shared_worker")
    assert_same handle1, @registry.get("shared_worker").handle
    assert_same ctx1, @registry.get("shared_worker").context
    assert_equal handle1.revision, @registry.revision_for("shared_worker")
    assert handle1.active?
    refute handle2.active?
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

    reserved_res = tool.execute(
      name: "pruner",
      description: "Attempt to replace the harness role",
      system_prompt: "This must not become the Pruner profile.",
      allow_override: true
    )
    assert reserved_res.respond_to?(:error?) && reserved_res.error?
    assert @registry.get("pruner").system_prompt.include?("Context Pruner subagent")
  end
end
