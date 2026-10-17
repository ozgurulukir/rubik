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

  def test_direct_type_definition_registration_validates_contract_and_replaces_untrusted_filter
    invalid = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "direct_invalid", description: "Invalid direct profile", system_prompt: "Do not register.",
      requires: ["unknown_service"], grants: [], context: @root_ctx
    )
    baseline = @registry.list.map(&:name).sort
    error = assert_raises(Rubik::Orchestrator::Subagent::ProfileValidationError) do
      @registry.register(invalid)
    end
    assert_equal "unknown_coeffect", JSON.parse(error.message).fetch("errors").first.fetch("code")
    assert_equal baseline, @registry.list.map(&:name).sort

    untrusted = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "direct_read_only", description: "Caller filter must not grant tools.",
      system_prompt: "Read only.", tool_filter: ->(_tool_name) { true }, grants: [], context: @root_ctx
    )
    handle = @registry.register(untrusted)

    assert_same untrusted, @registry.get("direct_read_only")
    assert_equal [], handle.grants
    refute handle.tool_filter.call("write_file")
    refute handle.tool_filter.call("invoke_subagent")
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

  def test_custom_profile_contract_defaults_to_least_privilege_and_expands_named_grants
    require "tmpdir"
    child_ctx = nil
    Dir.mktmpdir("rubik_profile_contract") do |root|
      source = Rubik::Tools::Registry.build_default(
        buffer_manager: Rubik::Buffer::Manager.new(root_dir: root), root_dir: root
      )
      root_names = source.list.map(&:name).sort
      root_invoke_tool = source.get("invoke_subagent")
      assert root_invoke_tool, "Maestro's root registry must expose invoke_subagent"

      default_profile = @registry.define_custom(
        name: "default_contract", description: "No elevated capabilities", system_prompt: "Read and report.",
        requires: ["storage"], context: @root_ctx
      )
      assert_equal [Rubik::Coeffects::STORAGE_STORE], default_profile.requires
      assert_equal [], default_profile.grants
      refute default_profile.enable_write_tools
      refute default_profile.enable_subagent_tools

      root_only = Rubik::Orchestrator::Subagent::ScopedRegistry::ROOT_ONLY_TOOLS
      write_tools = Rubik::Tools::Catalog.write_grant_tools
      spawn_tools = Rubik::Tools::Catalog.spawn_tools
      baseline = root_names.reject do |name|
        root_only.include?(name) || write_tools.include?(name) || spawn_tools.include?(name)
      end.sort

      child_ctx = @root_ctx.extend
      default_scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
        source_registry: source, type_def: default_profile, child_ctx: child_ctx, buffer: nil, parent_buffer: nil
      )
      assert_equal baseline, default_scoped.list.map(&:name).sort

      { "write_only" => ["write"], "spawn_only" => ["subagent_spawn"] }.each do |name, grants|
        profile = @registry.define_custom(
          name: name, description: "Single explicit grant", system_prompt: "Use only granted tools.",
          grants: grants, context: @root_ctx
        )
        grant_ctx = @root_ctx.extend
        scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
          source_registry: source, type_def: profile, child_ctx: grant_ctx, buffer: nil, parent_buffer: nil
        )
        expected = root_names.reject do |tool_name|
          root_only.include?(tool_name) ||
            (write_tools.include?(tool_name) && !grants.include?("write")) ||
            (spawn_tools.include?(tool_name) && !grants.include?("subagent_spawn"))
        end.sort

        assert_equal expected, scoped.list.map(&:name).sort, "#{name} must expose only its declared capability family"
      ensure
        grant_ctx&.dispose
      end

      granted_profile = @registry.define_custom(
        name: "granted_contract", description: "Explicitly elevated", system_prompt: "Work and delegate.",
        requires: ["llm_client"], grants: ["write", "subagent_spawn"], context: @root_ctx
      )
      assert_equal ["subagent_spawn", "write"], granted_profile.grants.sort
      assert_equal [Rubik::Coeffects::LLM_CLIENT], granted_profile.requires
      assert_raises(FrozenError) { granted_profile.grants.first.replace("subagent_spawn") }
      assert_raises(FrozenError) { Rubik::Orchestrator::Subagent::ProfileContract::CAPABILITY_GRANTS.first.replace("read") }

      child_ctx.dispose
      child_ctx = @root_ctx.extend
      granted_scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
        source_registry: source, type_def: granted_profile, child_ctx: child_ctx, buffer: nil, parent_buffer: nil
      )
      expected_granted = (root_names - root_only).sort
      assert_equal expected_granted, granted_scoped.list.map(&:name).sort

      # Nested profile definitions are scoped to this child context, so they
      # cannot leave a dynamic registration behind in the Maestro session.
      supervisor = Struct.new(:type_registry, :root_context).new(@registry, @root_ctx)
      @root_ctx.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, supervisor)
      define_tool = granted_scoped.get("define_subagent")
      assert_instance_of Rubik::Tools::DefineSubagentTool, define_tool
      assert_same child_ctx, define_tool.instance_variable_get(:@runtime_context)
      result = define_tool.execute(
        "name" => "nested_profile", "description" => "Child-owned", "system_prompt" => "Nested work."
      )
      refute result.respond_to?(:error?) && result.error?
      assert_same child_ctx, @registry.get("nested_profile").context

      assert_equal root_names, source.list.map(&:name).sort
      assert_same root_invoke_tool, source.get("invoke_subagent")
    ensure
      child_ctx&.dispose
    end

    assert_nil @registry.get("nested_profile"), "disposing the child must undo its nested definition"
  end

  def test_profile_contract_errors_are_structured_and_do_not_mutate_registry
    contract = Rubik::Orchestrator::Subagent::ProfileContract
    cases = [
      ["unknown coeffect", { name: "bad_coeffect", requires: ["not_a_service"] }, "unknown_coeffect"],
      ["unknown grant", { name: "bad_grant", grants: ["root_access"] }, "unknown_grant"],
      ["duplicate grant", { name: "duplicate_grant", grants: ["write", "write"] }, "duplicate_grant"],
      ["conflicting grant sources", { name: "conflicting_grants", grants: [], enable_write_tools: true }, "conflicting_grant_sources"],
      ["reserved name", { name: "VaKaNuViS", grants: ["write", "subagent_spawn"] }, "reserved_name"],
      ["long name", { name: "n" * (contract::FIELD_LIMITS.fetch(:name) + 1) }, "too_long"],
      ["long description", { name: "long_description", description: "d" * (contract::FIELD_LIMITS.fetch(:description) + 1) }, "too_long"],
      ["long system prompt", { name: "long_prompt", system_prompt: "p" * (contract::FIELD_LIMITS.fetch(:system_prompt) + 1) }, "too_long"]
    ]

    baseline = @registry.list.map(&:name).sort
    cases.each do |label, overrides, expected_code|
      profile_name = overrides.fetch(:name)
      arguments = {
        name: profile_name, description: "Profile", system_prompt: "Do the task.", context: @root_ctx
      }.merge(overrides)
      error = assert_raises(Rubik::Orchestrator::Subagent::ProfileValidationError, label) do
        @registry.define_custom(**arguments)
      end
      payload = JSON.parse(error.message)

      assert_equal "invalid_subagent_profile", payload.fetch("error"), label
      assert_includes payload.fetch("errors").map { |item| item.fetch("code") }, expected_code, label
      assert_equal baseline, @registry.list.map(&:name).sort, label
    end
  end

  def test_define_subagent_exposes_contract_schema_and_returns_structured_validation_errors
    schema = Rubik::Tools::DefineSubagentTool::DECLARATION.params_schema.fetch(:properties)
    assert_equal "array", schema.fetch(:requires).fetch(:type)
    assert_equal "array", schema.fetch(:grants).fetch(:type)
    assert_equal ["write", "subagent_spawn"], schema.fetch(:grants).fetch(:items).fetch(:enum)
    assert_equal Rubik::Orchestrator::Subagent::ProfileContract::FIELD_LIMITS.fetch(:system_prompt),
                 schema.fetch(:system_prompt).fetch(:maxLength)

    sup = Struct.new(:type_registry, :root_context).new(@registry, @root_ctx)
    tool = Rubik::Tools::DefineSubagentTool.new(supervisor: sup, runtime_context: @root_ctx)
    before = @registry.list.map(&:name).sort
    result = tool.execute(
      "name" => "bad_tool_profile", "description" => "Profile", "system_prompt" => "Do the task.",
      "requires" => ["unknown_runtime_service"]
    )

    assert result.error?
    payload = JSON.parse(result.to_s)
    assert_equal "invalid_subagent_profile", payload.fetch("error")
    assert_equal "unknown_coeffect", payload.fetch("errors").first.fetch("code")
    assert_equal before, @registry.list.map(&:name).sort
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
    assert_equal ["write"], handle.grants
    assert_equal [], handle.requires
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

    ["research", "coder", "self", "vakanuvis", "pruner"].each do |name|
      original = @registry.get(name)
      reserved_res = tool.execute(
        name: name,
        description: "Attempt to replace a built-in role",
        system_prompt: "This must not broaden the built-in policy.",
        grants: ["write", "subagent_spawn"], allow_override: true
      )
      assert reserved_res.respond_to?(:error?) && reserved_res.error?
      payload = JSON.parse(reserved_res.to_s)
      assert_includes payload.fetch("errors").map { |item| item.fetch("code") }, "reserved_name"
      assert_same original, @registry.get(name)
    end
  end
end
