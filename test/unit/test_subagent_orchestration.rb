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
    bus = Rubik::EventBus.new
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      event_bus: bus
    )
    completed_payload = nil
    paused_payload = nil
    # Raw symbols pin the public bus event names: third-party subscribers
    # subscribe to :subagent_completed / :subagent_budget_exhausted.
    bus.subscribe(:subagent_completed) { |p| completed_payload = p }
    bus.subscribe(:subagent_budget_exhausted) { |p| paused_payload = p }

    inst = supervisor.spawn(role: "Async Reporter", prompt: "Report test status")

    # Poll on the payload, not running?: the emit runs on the worker thread
    # AFTER the state flip (transcript save, cleanup, completion handling).
    deadline = Time.now + 3
    sleep 0.05 while completed_payload.nil? && Time.now < deadline

    assert_equal :completed, inst.state
    assert completed_payload, "Completion must arrive on the event bus"
    assert_equal inst.id, completed_payload[:id]
    assert_equal "Async Reporter", completed_payload[:role]
    assert_equal :completed, completed_payload[:state]
    refute completed_payload.key?(:result), "Notices announce only — results come via manage_subagents wait"
    refute paused_payload, "A completing worker must not emit a budget event"
    assert inst.uptime >= 0.0

    supervisor.shutdown_all
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
    status_data = JSON.parse(status_res)
    assert status_data.key?("result")
    assert status_data.key?("transcript")

    # Transcript action
    sleep 0.05 while inst.running?
    transcript_res = tool.execute("action" => "transcript", "conversation_id" => inst.id)
    assert_includes transcript_res, "=== Subagent Transcript:"
    assert_includes transcript_res, inst.id

    # Read transcript via ReadFileTool using rubik:// URI
    read_tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    read_res = read_tool.execute("path" => "rubik://subagent/#{inst.id}/transcript")
    refute_includes read_res, "FILE NOT FOUND"
    assert_includes read_res, inst.id

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

  # =========================================================================
  # 13. Zero-Restart Context Cleanup & Disposable Count Invariant
  # =========================================================================

  def test_subagent_zero_restart_context_cleanup_and_disposable_count
    baseline_disposables = @root_context.disposable_count

    inst = @supervisor.spawn(role: "Leak Test Worker", prompt: "Complete fast")
    deadline = Time.now + 3
    sleep 0.05 while inst.running? && Time.now < deadline

    assert_equal :completed, inst.state
    assert inst.context.disposed?, "Child context must be disposed upon completion"
    assert_equal baseline_disposables, @root_context.disposable_count,
                 "Root context disposables must return to baseline after subagent completion"
  end

  # =========================================================================
  # 14. Branch Workspace Isolation and Atomic Merge / Rollback
  # =========================================================================

  def test_branch_workspace_isolation_and_atomic_merge_on_success
    test_file = File.join(Dir.pwd, "tmp_test_branch.txt")
    inst = @supervisor.spawn(
      type_name: "coder",
      role: "Branch Worker",
      prompt: "Edit file in branch",
      workspace: "branch"
    )

    refute_same @buffer_manager, inst.buffer_manager
    sleep 0.02 while inst.running?
    inst.buffer_manager.write(test_file, "branch content")
    assert inst.buffer_manager.dirty?(test_file)

    @supervisor.send(:handle_subagent_completion, inst)
    assert @buffer_manager.dirty?(test_file)
    assert_equal "branch content", @buffer_manager.read(test_file)
  ensure
    @buffer_manager.dirty_files.delete(test_file)
  end

  def test_branch_workspace_rollback_on_failure
    test_file = File.join(Dir.pwd, "tmp_test_rollback.txt")
    inst = @supervisor.spawn(
      type_name: "coder",
      role: "Failing Branch Worker",
      prompt: "Crash after editing",
      workspace: "branch"
    )

    inst.buffer_manager.write(test_file, "uncommitted changes")
    inst.instance_variable_set(:@state, :failed)

    @supervisor.send(:handle_subagent_completion, inst)
    refute @buffer_manager.dirty?(test_file), "Failed branch workspace changes must not merge into parent buffer"
  end

  def test_orphan_reaping_and_reparenting_to_init0
    inst1 = @supervisor.spawn(role: "Parent Worker", prompt: "P")
    inst2 = @supervisor.spawn(role: "Child Worker", prompt: "C", parent_id: inst1.id)

    assert_equal inst1.id, inst2.parent_id

    @supervisor.kill(inst1.id)
    @supervisor.reap_orphans

    assert_equal "agent-0", inst2.parent_id, "Active child must be reparented to root agent-0 when parent dies"
  end

  # =========================================================================
  # 15. Subagent Step Budget Negotiation & Archetype Inference
  # =========================================================================

  def test_subagent_budget_warning_at_75_percent
    call_count = 0
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    resp_done = Struct.new(:content, :tool_calls).new("Done", [])

    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      call_count += 1
      call_count < 4 ? resp_tool : resp_done
    end

    inst = @supervisor.spawn(
      role: "Warning Worker",
      prompt: "Step test",
      provider: provider,
      max_steps: 4
    )

    deadline = Time.now + 3
    sleep 0.02 while inst.running? && Time.now < deadline

    assert_equal :completed, inst.state
    warning = inst.history.find { |msg| msg[:content]&.include?("[Step budget warning]") }
    refute_nil warning, "Budget warning must be injected into history at 75% of max_steps"
    assert_includes warning[:content], "Used 3/4 steps"
  end

  def test_subagent_budget_expansion_resumes_waiting_worker
    call_count = 0
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    resp_done = Struct.new(:content, :tool_calls).new("Finished work", [])

    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      call_count += 1
      call_count <= 2 ? resp_tool : resp_done
    end

    bus = Rubik::EventBus.new
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      event_bus: bus
    )
    paused_payload = nil
    bus.subscribe(Rubik::Orchestrator::Subagent::Notices::BUDGET_EXHAUSTED_EVENT) { |p| paused_payload = p }

    inst = supervisor.spawn(
      role: "Extensible Worker",
      prompt: "Long task",
      provider: provider,
      max_steps: 2
    )

    deadline = Time.now + 3
    sleep 0.02 while (paused_payload.nil? || inst.state == :running) && Time.now < deadline

    assert_equal :waiting_budget, inst.state
    assert paused_payload, "Budget pause must arrive on the event bus"
    assert_equal inst.id, paused_payload[:id]
    assert_equal :waiting_budget, paused_payload[:state]
    assert_equal 2, paused_payload[:max_steps]
    assert_equal 2, inst.current_step

    ok = supervisor.extend_budget(inst.id, 5)
    assert ok
    assert_equal 7, inst.max_steps

    deadline = Time.now + 3
    sleep 0.02 while inst.running? && Time.now < deadline

    assert_equal :completed, inst.state
    assert_equal "Finished work", inst.result

    supervisor.shutdown_all
  end

  def test_pause_and_await_budget_expansion_timeout
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp_tool }

    cfg = Rubik::Config.new
    cfg.set("subagents.budget_wait_timeout", 0.05)
    bus = Rubik::EventBus.new
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      event_bus: bus,
      config: cfg
    )
    completed_payload = nil
    bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT) { |p| completed_payload = p }

    inst = supervisor.spawn(role: "Timeout Worker", prompt: "Work", provider: provider, max_steps: 2)

    deadline = Time.now + 3
    sleep 0.02 while completed_payload.nil? && Time.now < deadline

    assert_equal :budget_exhausted, inst.state, "State must be :budget_exhausted, never :completed"
    refute inst.active?, "A budget-exhausted subagent is not active"
    refute inst.running?, "A budget-exhausted subagent is not running"
    assert_includes inst.result, "Subagent reached step budget (2 steps) and halted: task was NOT completed."
    assert_includes inst.result, "Budget expansion was not received from init-0."
    assert completed_payload, "the terminal COMPLETED event must fire for the timed-out worker"
    assert_equal :budget_exhausted, completed_payload[:state]
    assert_equal 2, completed_payload[:max_steps], "COMPLETED carries max_steps for the count-bearing guidance"

    supervisor.shutdown_all
  end

  def test_manage_subagents_tool_extend_budget
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Budget Agent", prompt: "Awaiting budget", max_steps: 5)
    inst.instance_variable_set(:@state, :waiting_budget)

    status_res = tool.execute("action" => "status", "conversation_id" => inst.id)
    assert_includes status_res, "waiting_budget"
    assert_includes status_res, "extend_budget"

    extend_res = tool.execute("action" => "extend_budget", "conversation_id" => inst.id, "steps" => 10)
    assert_includes extend_res, "successfully extended by 10 steps"
    assert_equal 15, inst.max_steps
    assert_equal :running, inst.state
  end

  def test_send_message_tool_with_steps_grant
    msg_tool = Rubik::Tools::SendMessageTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Waiting Agent", prompt: "Work", max_steps: 5)
    inst.instance_variable_set(:@state, :waiting_budget)

    res = msg_tool.execute(
      "recipient" => inst.id,
      "message" => "Take 10 more steps to finish",
      "steps" => 10
    )
    assert_includes res, "Message successfully delivered"
    assert_equal 15, inst.max_steps
    assert_equal :running, inst.state
  end

  def test_manage_subagents_tool_extend_and_resume_budget_exhausted
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Exhausted Agent", prompt: "Work", max_steps: 5)
    inst.instance_variable_set(:@state, :budget_exhausted)

    # 1. extend_budget action
    extend_res = tool.execute("action" => "extend_budget", "conversation_id" => inst.id, "steps" => 15)
    assert_includes extend_res, "successfully extended by 15 steps"
    assert_equal 20, inst.max_steps
    assert_equal :running, inst.state

    # 2. resume action on budget_exhausted
    inst.instance_variable_set(:@state, :budget_exhausted)
    resume_res = tool.execute("action" => "resume", "conversation_id" => inst.id, "steps" => 10)
    assert_includes resume_res, "successfully resumed"
    assert_equal 30, inst.max_steps
    assert_equal :running, inst.state

    # 3. send_message action with steps on budget_exhausted
    inst.instance_variable_set(:@state, :budget_exhausted)
    msg_tool = Rubik::Tools::SendMessageTool.new(supervisor: @supervisor, runtime_context: @root_context)
    msg_res = msg_tool.execute("recipient" => inst.id, "message" => "Finish task", "steps" => 10)
    assert_includes msg_res, "Message successfully delivered"
    assert_equal 40, inst.max_steps
    assert_equal :running, inst.state
  end

  def test_send_message_to_parent_agent
    bus = Rubik::EventBus.new
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      event_bus: bus
    )
    msg_tool = Rubik::Tools::SendMessageTool.new(supervisor: supervisor, runtime_context: @root_context)
    parent_msgs = []
    bus.subscribe(:subagent_message_to_parent) { |p| parent_msgs << p }

    res = msg_tool.execute("recipient" => "agent-0", "message" => "Review complete with 3 findings")
    assert_includes res, "Message successfully delivered to subagent 'agent-0'"
    assert_equal 1, parent_msgs.size
    assert_equal "Review complete with 3 findings", parent_msgs.first[:message]
  end

  def test_smart_archetype_inference
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: @supervisor, runtime_context: @root_context)

    coder_specs = [
      { "role" => "Debugger", "prompt" => "Fix auth token expiration bug" },
      { "role" => "Developer", "prompt" => "Patch security guard rule in guard.rb" },
      { "role" => "Engineer", "prompt" => "Implement budget negotiation protocol" },
      { "role" => "Refactorer", "prompt" => "Refactor context manager methods" },
      { "role" => "Writer", "prompt" => "Write new test cases for subagent" },
      { "role" => "Editor", "prompt" => "Edit prompt builder templates" }
    ]

    coder_specs.each do |args|
      specs = tool.send(:extract_subagent_specs, args)
      assert_equal "coder", specs.first[:type_name], "Expected 'coder' archetype for: #{args['prompt']}"
    end

    research_specs = [
      { "role" => "Researcher", "prompt" => "Explore the project file tree and architecture" },
      { "role" => "Analyst", "prompt" => "Check status of open background tasks" }
    ]

    research_specs.each do |args|
      specs = tool.send(:extract_subagent_specs, args)
      assert_equal "research", specs.first[:type_name], "Expected 'research' archetype for: #{args['prompt']}"
    end

    explicit_spec = tool.send(:extract_subagent_specs, "type_name" => "custom", "role" => "Worker", "prompt" => "Fix bug")
    assert_equal "custom", explicit_spec.first[:type_name]
  end

  def test_repl_subagents_extend_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)
    sup = Rubik::REPL::Commands::Subagents.resolve_supervisor(shell)

    inst = sup.spawn(role: "REPL Worker", prompt: "Work", max_steps: 5)
    inst.instance_variable_set(:@state, :waiting_budget)

    shell.execute_command(Rubik::REPL::CommandParser.parse("!subagents extend #{inst.id} 15"))
    assert_includes out.string, "Extended budget for #{inst.id} by 15 steps"
    assert_equal 20, inst.max_steps
    assert_includes [:running, :completed], inst.state

    shell.stop
  end

  def test_repl_subagents_extend_command_defaults_to_grant_constant
    resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, provider: provider)

    inst = sup.spawn(role: "REPL Default Grant", prompt: "Work", max_steps: 5)
    deadline = Time.now + 3
    sleep 0.02 while inst.state != :waiting_budget && Time.now < deadline
    assert_equal :waiting_budget, inst.state, "worker must genuinely pause at its step budget first"

    out = StringIO.new
    Rubik::REPL::Commands::Subagents.handle_extend(Struct.new(:out).new(out), sup, inst.id, nil)

    assert_includes out.string, "by 20 steps", "no-arg extend grants Budget::DEFAULT_GRANT_STEPS, not the old drifted 10"
    assert_equal 25, inst.max_steps

    sup.shutdown_all
  end

  def test_supervisor_wait_for
    inst1 = @supervisor.spawn(role: "Fast Worker 1", prompt: "P1")
    inst2 = @supervisor.spawn(role: "Fast Worker 2", prompt: "P2")

    results = @supervisor.wait_for([inst1.id, inst2.id], timeout: 3)
    assert_equal 2, results.size
    assert_equal "completed", results.first[:state]
    assert_equal "completed", results.last[:state]
  end

  def test_manage_subagents_tool_wait_action
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Waitable Worker", prompt: "Do quick work")

    res = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 3)
    assert_includes res, "Subagents wait finished"
    assert_includes res, inst.id
    assert_includes res, "COMPLETED"
  end

  def test_repl_subagents_wait_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)
    sup = Rubik::REPL::Commands::Subagents.resolve_supervisor(shell)

    inst = sup.spawn(role: "REPL Waitable", prompt: "Quick work")

    shell.execute_command(Rubik::REPL::CommandParser.parse("!subagents wait #{inst.id} 3"))
    assert_includes out.string, "Subagents Wait Finished"
    assert_includes out.string, inst.id

    shell.stop
  end

  def test_default_max_steps_from_config
    # Default without explicit config should be 88
    inst_default = @supervisor.spawn(role: "Default Budget Worker", prompt: "Work")
    assert_equal 88, inst_default.max_steps

    # Custom config
    custom_cfg = Rubik::Config.new
    custom_cfg.set("subagents.default_max_steps", 42)
    sup_custom = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      config: custom_cfg
    )
    assert_equal 42, sup_custom.default_max_steps
    inst_custom = sup_custom.spawn(role: "Custom Budget Worker", prompt: "Work")
    assert_equal 42, inst_custom.max_steps

    sup_custom.shutdown_all
  end

  def test_manage_subagents_wait_with_budget_pause_guidance
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Exhausted Worker", prompt: "Work", max_steps: 5)
    inst.instance_variable_set(:@state, :waiting_budget)

    res = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 1)
    assert_includes res, "WAITING_BUDGET"
    assert_includes res, "Guidance: Subagent reached step budget (5 steps) and paused."
    assert_includes res, "manage_subagents(action: 'extend_budget', conversation_id: '#{inst.id}', steps: 20)"

    # Test budget_exhausted guidance
    inst.instance_variable_set(:@state, :budget_exhausted)
    res_exhausted = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 1)
    assert_includes res_exhausted, "BUDGET_EXHAUSTED"
    assert_includes res_exhausted, "Guidance: Subagent reached step budget (5 steps) and halted: task was NOT completed. Inspect transcript or spawn a new subagent."
  end

  def test_shell_subagent_notices_buffered_during_active_loop
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)
    # The routing gate reads @running (only Shell#run sets it); drive the seam
    # as a running shell would.
    shell.instance_variable_set(:@running, true)

    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |notice| received << notice }
    shell.instance_variable_set(:@active_loop, mock_loop)

    # Drive the REAL seam end-to-end: emit contract -> bus -> subscriber -> route.
    shell.event_bus.emit(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                         { id: "subagent-99", role: "Worker", state: :completed })

    # Output must NOT have the notice while @active_loop is running; the model
    # channel is buffered into the loop queue instead.
    refute_includes out.string, "subagent-99"
    assert_equal 1, received.size
    assert_equal :completed, received.first[:kind]
    assert_equal "subagent-99", received.first[:id]

    # End of turn clears @active_loop and flushes the buffered user channel
    shell.instance_variable_set(:@active_loop, nil)
    shell.flush_subagent_notices!

    assert_includes out.string, "subagent-99"
    assert_includes out.string, "⚡ [Subagent Completed]"

    shell.stop
  end
end
