# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSubagentOrchestration < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: Dir.pwd)
    @tool_registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      root_dir: Dir.pwd
    )
    @supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      buffer_manager: @buffer_manager,
      tool_registry: @tool_registry
    )
  end

  def teardown
    @supervisor&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
  end

  # =========================================================================
  # 1. Linux Init Tree & Hierarchy Tests
  # =========================================================================

  def test_subagent_hierarchy_and_tree
    inst1 = @supervisor.spawn(role: "Codebase Researcher", prompt: "Search auth methods")
    assert_equal "subagent-1", inst1.id
    assert_equal "agent-0", inst1.parent_id
    assert_equal "Codebase Researcher", inst1.role

    inst2 = @supervisor.spawn(role: "Security Reviewer", prompt: "Review guards", parent_id: inst1.id)
    assert_equal "subagent-2", inst2.id
    assert_equal "subagent-1", inst2.parent_id
  end

  # =========================================================================
  # 2. Async Non-Blocking Start
  # =========================================================================

  def test_subagent_async_non_blocking_start
    t0 = Time.now
    inst = @supervisor.spawn(role: "Fast Worker", prompt: "Quick task")
    elapsed = Time.now - t0

    # Must return immediately (< 0.1s)
    assert elapsed < 0.1, "spawn must return asynchronously in < 100ms, took #{elapsed}s"
    assert_includes [:running, :completed], inst.state
  end

  # =========================================================================
  # 3. Reactive Completion Notification
  # =========================================================================

  def test_subagent_reactive_completion_notification
    completed_notified = false
    inst = @supervisor.spawn(
      role: "Async Reporter",
      prompt: "Report test status",
      on_notify: ->(i) { completed_notified = true if i.id == inst.id }
    )

    deadline = Time.now + 3
    sleep 0.05 while inst.running? && Time.now < deadline

    assert_equal :completed, inst.state
    assert completed_notified, "Supervisor on_notify callback should trigger on completion"
    assert inst.uptime >= 0.0
  end

  # =========================================================================
  # 4. Custom vs Inherited System Prompts
  # =========================================================================

  def test_custom_and_inherited_system_prompts
    inst_custom = @supervisor.spawn(
      role: "Custom Specialist",
      prompt: "Do special audit",
      system_prompt: "STRICT SECURITY RULES: Never allow eval."
    )
    assert_includes inst_custom.send(:build_effective_system_prompt), "STRICT SECURITY RULES: Never allow eval."

    inst_default = @supervisor.spawn(
      role: "Standard Explorer",
      prompt: "Explore codebase"
    )
    assert_includes inst_default.send(:build_effective_system_prompt), "Codebase Research Subagent"
  end

  # =========================================================================
  # 5. Research Role Tool Privilege Filtering (Least Privilege)
  # =========================================================================

  def test_research_role_tool_privilege_filtering
    inst = @supervisor.spawn(
      type_name: "research",
      role: "Read-Only Researcher",
      prompt: "Find all usages of TaskManager"
    )
    reg = inst.tool_registry
    assert reg, "Scoped registry must be created for subagent"

    # Must contain read tools
    assert reg.get("read_file"), "read_file must be present in research subagent"
    assert reg.get("grep_search"), "grep_search must be present in research subagent"
    assert reg.get("search_symbols"), "search_symbols must be present in research subagent"

    # Must NOT contain mutating or spawning tools
    assert_nil reg.get("write_file"), "write_file must be excluded from research subagent"
    assert_nil reg.get("replace_file_content"), "replace_file_content must be excluded"
    assert_nil reg.get("invoke_subagent"), "invoke_subagent must be excluded from subagent"
  end

  # =========================================================================
  # 6. Dynamic Archetype Definition
  # =========================================================================

  def test_dynamic_archetype_definition
    @supervisor.type_registry.define_custom(
      name: "tester",
      description: "Dedicated test runner subagent",
      system_prompt: "You run unit and integration tests.",
      enable_write_tools: false,
      enable_subagent_tools: false
    )

    inst = @supervisor.spawn(
      type_name: "tester",
      role: "Test Agent",
      prompt: "Run suite"
    )
    assert_equal "tester", inst.type_name
    assert_includes inst.send(:build_effective_system_prompt), "You run unit and integration tests."
  end

  # =========================================================================
  # 7. Recursion Depth Guard
  # =========================================================================

  def test_recursion_depth_guard
    inst1 = @supervisor.spawn(role: "Depth 1", prompt: "P1", parent_id: "agent-0")
    inst2 = @supervisor.spawn(role: "Depth 2", prompt: "P2", parent_id: inst1.id)

    # Spawning Depth 3 should raise DepthExceededError
    assert_raises(Rubik::Orchestrator::Subagent::DepthExceededError) do
      @supervisor.spawn(role: "Depth 3", prompt: "P3", parent_id: inst2.id)
    end
  end

  # =========================================================================
  # 8. Concurrency Limit
  # =========================================================================

  def test_concurrency_limit
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      config: { "subagents.max_concurrency" => 2 }
    )

    # Spawn 2 subagents with delayed mock execution
    inst1 = supervisor.spawn(role: "Worker 1", prompt: "W1")
    inst2 = supervisor.spawn(role: "Worker 2", prompt: "W2")

    # Manually hold state as running to test concurrency check
    inst1.instance_variable_set(:@state, :running)
    inst2.instance_variable_set(:@state, :running)

    assert_raises(Rubik::Orchestrator::Subagent::ConcurrencyExceededError) do
      supervisor.spawn(role: "Worker 3", prompt: "W3")
    end

    supervisor.shutdown_all
  end

  # =========================================================================
  # 9. Inter-Agent Messaging
  # =========================================================================

  def test_inter_agent_messaging
    inst = @supervisor.spawn(role: "Interactive Worker", prompt: "Awaiting inputs")
    inst.instance_variable_set(:@state, :running)

    ok = @supervisor.send_message(inst.id, "Here is an extra hint")
    assert ok
    refute inst.instance_variable_get(:@inbox).empty?

    # Target invalid subagent
    refute @supervisor.send_message("nonexistent-99", "Hello")
  end

  # =========================================================================
  # 10. Init 0 Graceful Shutdown & LIFO Cleanup
  # =========================================================================

  def test_init_0_graceful_shutdown_and_lifo_cleanup
    inst1 = @supervisor.spawn(role: "Child 1", prompt: "Task 1")
    inst2 = @supervisor.spawn(role: "Child 2", prompt: "Task 2")

    assert @supervisor.get(inst1.id)
    assert @supervisor.get(inst2.id)

    # Shutdown all subagents in LIFO order
    @supervisor.shutdown_all
    assert_empty @supervisor.instances

    assert_equal :disposed, inst1.state
    assert_equal :disposed, inst2.state
    assert inst1.context.disposed?
    assert inst2.context.disposed?
  end

  # =========================================================================
  # 11. Tool Integration Tests
  # =========================================================================

  def test_invoke_subagent_tool
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: @supervisor, runtime_context: @root_context)

    # 1. Single subagent format
    res1 = tool.execute("role" => "Single Researcher", "prompt" => "Investigate models")
    assert_includes res1, "Launched 1 background subagent(s):"
    assert_includes res1, "Single Researcher"

    # 2. Multi subagent array format
    res2 = tool.execute(
      "subagents" => [
        { "role" => "Worker A", "prompt" => "Task A" },
        { "role" => "Worker B", "prompt" => "Task B" }
      ]
    )
    assert_includes res2, "Launched 2 background subagent(s):"
    assert_includes res2, "Worker A"
    assert_includes res2, "Worker B"
  end

  def test_manage_subagents_tool
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)

    inst = @supervisor.spawn(role: "Manageable", prompt: "Run briefly")

    # List action
    list_res = tool.execute("action" => "list")
    assert_includes list_res, inst.id
    assert_includes list_res, "Manageable"

    # Status action
    status_res = tool.execute("action" => "status", "conversation_id" => inst.id)
    assert_includes status_res, inst.id

    # Kill action
    kill_res = tool.execute("action" => "kill", "conversation_ids" => [inst.id])
    assert_includes kill_res, "Killed subagent(s): #{inst.id}"
  end

  def test_send_message_and_define_subagent_tools
    msg_tool = Rubik::Tools::SendMessageTool.new(supervisor: @supervisor, runtime_context: @root_context)
    def_tool = Rubik::Tools::DefineSubagentTool.new(supervisor: @supervisor, runtime_context: @root_context)

    # Define subagent archetype
    def_res = def_tool.execute(
      "name" => "analyst",
      "description" => "Data analyst",
      "system_prompt" => "Analyze data"
    )
    assert_includes def_res, "Subagent archetype 'analyst' successfully defined"
    assert @supervisor.type_registry.get("analyst")

    # Spawn and send message
    inst = @supervisor.spawn(type_name: "analyst", role: "Metrics Analyst", prompt: "Gather stats")
    msg_res = msg_tool.execute("recipient" => inst.id, "message" => "Focus on memory")
    assert_includes msg_res, "Message successfully delivered"
  end

  # =========================================================================
  # 12. REPL !subagents Command Tests
  # =========================================================================

  def test_repl_subagents_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)

    # Empty list
    shell.execute_command(Rubik::REPL::CommandParser.parse("!subagents list"))
    assert_includes out.string, "No subagents currently running"

    # Spawn via tool
    tool = shell.tool_registry.get("invoke_subagent")
    tool.execute("role" => "REPL Worker", "prompt" => "Assist user")

    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!subagents list"))
    assert_includes out.string, "REPL Worker"

    # Types command
    out.reopen
    shell.execute_command(Rubik::REPL::CommandParser.parse("!subagents types"))
    assert_includes out.string, "research"
    assert_includes out.string, "self"
    assert_includes out.string, "coder"

    shell.stop
  end
end
