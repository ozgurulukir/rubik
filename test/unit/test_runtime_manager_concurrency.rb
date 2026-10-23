# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "open3"

class TestRuntimeManagerConcurrency < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_rt_test")
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
  end

  def teardown
    @manager.dispose!
    FileUtils.remove_entry(@temp_dir)
  end

  # 1. 10 thread concurrent register_component stress test
  def test_concurrent_register_component_stress
    thread_count = 10
    fibers_per_thread = 20
    threads = []

    thread_count.times do |t_idx|
      threads << Thread.new do
        fibers_per_thread.times do |f_idx|
          name = "fiber_#{t_idx}_#{f_idx}"
          @manager.register_component(name) do |_ctx, _cfg|
            { id: name }
          end
        end
      end
    end

    threads.each(&:join)

    total_expected = thread_count * fibers_per_thread
    assert_equal total_expected, @manager.fibers.size
    assert_equal total_expected, @manager.active_fibers.size
    assert_empty @manager.pending_fibers
    assert_empty @manager.failed_fibers
  end

  # 2. Concurrent provide and reconcile_all test
  def test_concurrent_provide_and_reconcile_all
    # Register 30 fibers requiring "database" service and 30 requiring "cache" service
    30.times do |i|
      @manager.register_component("db_client_#{i}", inject: ["database"]) do |ctx|
        ctx.require("database")
      end
      @manager.register_component("cache_client_#{i}", inject: ["cache"]) do |ctx|
        ctx.require("cache")
      end
    end

    assert_equal 60, @manager.pending_fibers.size
    assert_empty @manager.active_fibers

    threads = []
    # Concurrently provide services, trigger reconcile_all, and query fibers
    threads << Thread.new { @manager.provide("database", { connection: "db_active" }) }
    threads << Thread.new { @manager.provide("cache", { connection: "cache_active" }) }

    4.times do
      threads << Thread.new do
        5.times do
          @manager.reconcile_all
          _ = @manager.active_fibers
          _ = @manager.pending_fibers
          _ = @manager.fibers
          sleep 0.001
        end
      end
    end

    threads.each(&:join)

    assert_equal 60, @manager.active_fibers.size
    assert_empty @manager.pending_fibers
    assert_empty @manager.failed_fibers
  end

  # 3. swap_component re-entrancy test
  def test_swap_component_reentrancy
    @manager.provide("auth", { token: "secret" })

    @manager.register_component("worker", inject: ["auth"]) do |ctx|
      { auth: ctx.require("auth"), version: 1 }
    end

    assert_equal 1, @manager.active_fibers.size
    assert_equal 1, @manager.fibers["worker"]&.instance&.dig(:version)

    # Monitor re-entrancy check: swap_component calls unregister_component and register_component
    # inside @monitor.synchronize without deadlock.
    # Furthermore, factory accesses manager methods inside the same thread.
    @manager.swap_component("worker", inject: ["auth"]) do |ctx|
      # Nested read from manager inside fiber activation while monitor is locked
      active_count = @manager.active_fibers.size
      { auth: ctx.require("auth"), version: 2, seen_active: active_count }
    end

    fiber = @manager.fibers["worker"]
    assert_equal :active, fiber.state
    assert_equal 2, fiber.instance[:version]

    # Concurrent swapping stress
    threads = (1..5).map do |v|
      Thread.new do
        @manager.swap_component("worker", inject: ["auth"]) do |ctx|
          { auth: ctx.require("auth"), version: 10 + v }
        end
      end
    end
    threads.each(&:join)

    final_fiber = @manager.fibers["worker"]
    assert_equal :active, final_fiber.state
    assert_includes 11..15, final_fiber.instance[:version]
  end

  # 4. LSP::Client#document_open? and Manager#sync_buffer_file encapsulation test
  def test_lsp_client_document_open_and_manager_encapsulation
    client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir)
    file_path = File.join(@temp_dir, "app.rb")

    # Initial state: document is not open
    refute client.document_open?(file_path)

    # Directly verify thread-safe state when recorded
    client.instance_variable_get(:@mutex).synchronize do
      client.instance_variable_get(:@open_documents)[File.expand_path(file_path)] = 1
    end
    assert client.document_open?(file_path)

    client.instance_variable_get(:@mutex).synchronize do
      client.instance_variable_get(:@open_documents).delete(File.expand_path(file_path))
    end
    refute client.document_open?(file_path)

    # Nil and empty string safety
    refute client.document_open?(nil)
    refute client.document_open?("")
    refute client.document_open?("   ")

    # Manager#sync_buffer_file encapsulation test
    config = Rubik::Config.new(root_dir: @temp_dir)
    config.set("lsp.enabled", true)
    lsp_mgr = Rubik::LSP::Manager.new(root_dir: @temp_dir, config: config)

    opened = false
    changed = false
    is_doc_open = false

    mock_client = Object.new
    mock_client.define_singleton_method(:running) { true }
    mock_client.define_singleton_method(:document_open?) do |_path|
      is_doc_open
    end
    mock_client.define_singleton_method(:did_open) do |_path, _content, _language_id|
      opened = true
      is_doc_open = true
      true
    end
    mock_client.define_singleton_method(:did_change) do |_path, _content|
      changed = true
      true
    end

    lsp_mgr.stub(:client_for, mock_client) do
      # First sync: not open -> should call did_open
      lsp_mgr.sync_buffer_file(file_path, "def hello; end")
      assert opened, "Expected did_open to be called on first sync"
      refute changed, "Expected did_change NOT to be called on first sync"

      # Second sync: now open -> should call did_change
      lsp_mgr.sync_buffer_file(file_path, "def hello; :world; end")
      assert changed, "Expected did_change to be called on second sync"
    end
  end

  # 5. AST graph warm failure emits :ast_warm_failed event and warns logger
  def test_ast_graph_warm_failure_emits_event_and_logs_warning
    output = StringIO.new
    shell = Rubik::REPL::Shell.new(output: output)

    warned_messages = []
    mock_logger = Object.new
    mock_logger.define_singleton_method(:warn) { |msg| warned_messages << msg }
    mock_logger.define_singleton_method(:info) { |_| }
    mock_logger.define_singleton_method(:error) { |_| }
    mock_logger.define_singleton_method(:debug) { |_| }
    shell.instance_variable_set(:@logger, mock_logger)

    emitted_events = []
    shell.event_bus.subscribe(:ast_warm_failed) do |payload|
      emitted_events << payload
    end

    # Cause perform_warm_ast_graph to fail inside purge_stale_entries!
    Rubik::Runtime::ASTService.stub(:purge_stale_entries!, ->(*) { raise StandardError, "simulated ast failure" }) do
      res = shell.send(:perform_warm_ast_graph)
      assert_nil res
    end

    assert_equal 1, emitted_events.size
    assert_equal "simulated ast failure", emitted_events.first[:error]
    assert warned_messages.any? { |m| m.include?("AST graph warm failed: simulated ast failure") },
           "Expected logger warning for AST warm failure"
  ensure
    shell&.stop
  end

  # 6. ProcessDriver does not inject fake proxy environment variables into host
  def test_sandbox_driver_process_no_fake_proxy_env
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    captured_env = nil

    Open3.stub :popen3, lambda { |env, *_args, &block|
      captured_env = env
      mock_thr = Struct.new(:value, :pid).new(Struct.new(:exitstatus).new(0), 99_999)
      block.call(StringIO.new, StringIO.new("ok"), StringIO.new(""), mock_thr)
    } do
      driver.run("echo test", chdir: @temp_dir, allow_network: false)
    end

    refute_nil captured_env
    assert_empty captured_env
  end

  # 7. Safe iteration under reconcile_all when fiber activation registers a child fiber
  def test_reconcile_all_handles_fiber_registration_during_iteration
    @manager.provide("db", { ready: true })

    # Fiber parent registers a child fiber inside its factory when activated
    @manager.register_component("parent", inject: ["db"]) do |ctx|
      @manager.register_component("child", inject: ["db"]) do
        { role: :child }
      end
      { role: :parent, db: ctx.require("db") }
    end

    assert_equal 2, @manager.active_fibers.size
    assert_equal :active, @manager.fibers["parent"]&.state
    assert_equal :active, @manager.fibers["child"]&.state

    # Trigger reconcile_all with changed_service — shouldn't crash with hash iteration error
    @manager.reconcile_all(changed_service: "db")
    assert_equal 2, @manager.active_fibers.size
  end

  # ── Legacy alias reactive symmetry ───────────────────────────────────

  # A fiber injected with a legacy alias key must react to canonical
  # re-provides: reactivate! re-runs the factory so the fiber picks up the
  # new service instance (zero-downtime swap, AGENTS.md §3.2).
  def test_alias_injected_fiber_reactivates_on_canonical_reprovide
    instances = []
    @manager.register_component("alias_dep", inject: ["llm"]) do |ctx|
      instances << ctx.require(:llm)
    end

    @manager.provide(:llm_client, "v1")
    assert_equal :active, @manager.fibers["alias_dep"]&.state
    assert_equal ["v1"], instances

    @manager.provide(:llm_client, "v2")
    assert_equal ["v1", "v2"], instances, "alias-injected fiber must re-run its factory on canonical re-provide"
  end

  # Negative match: an unrelated re-provide must NOT re-run the factory
  # (a wrong match would duplicate factory side effects on every provide).
  def test_alias_injected_fiber_ignores_unrelated_reprovides
    runs = 0
    @manager.register_component("alias_dep", inject: ["llm"]) do |ctx|
      runs += 1
      ctx.require(:llm)
    end

    @manager.provide(:llm_client, "v1")
    @manager.provide(:config, { a: 1 })
    @manager.provide(:buffer_manager, Object.new)

    assert_equal 1, runs, "factory must run exactly once — unrelated provides must not reactivate"
  end

  # Control: literal canonical injection keeps its existing reactivation.
  def test_canonical_injected_fiber_reactivates_on_canonical_reprovide
    instances = []
    @manager.register_component("canonical_dep", inject: ["llm_client"]) do |ctx|
      instances << ctx.require(:llm_client)
    end

    @manager.provide(:llm_client, "v1")
    @manager.provide(:llm_client, "v2")

    assert_equal ["v1", "v2"], instances
  end

  # A pending fiber injected with an alias activates once the canonical
  # service satisfies the coeffect (satisfiability bridge symmetry).
  def test_pending_alias_injected_fiber_activates_on_canonical_provide
    activated = []
    @manager.register_component("late_alias_dep", inject: ["tools"]) do |ctx|
      activated << ctx.require(:tools)
    end

    assert_equal :pending, @manager.fibers["late_alias_dep"]&.state

    @manager.provide(:tool_registry, "registry")
    assert_equal :active, @manager.fibers["late_alias_dep"]&.state
    assert_equal ["registry"], activated
  end

  # ── Plan 86 D-3: requires: reactive gating ──────────────────────────

  def test_requires_gated_fiber_waits_for_prerequisite_then_activates
    built = []
    @manager.register_component("gated_dep", inject: ["shell"], requires: ["tool_registry"]) do |ctx|
      built << [ctx.require(:shell), ctx.require(:tool_registry)]
    end

    @manager.provide(:shell, "shell") # inject satisfied, requires: missing
    assert_equal :pending, @manager.fibers["gated_dep"]&.state, "requires: gate must hold the fiber pending"

    @manager.provide(:tool_registry, "registry") # last prerequisite arrives
    assert_equal :active, @manager.fibers["gated_dep"]&.state
    assert_equal [["shell", "registry"]], built
  end

  def test_requires_default_keeps_register_component_backward_compatible
    @manager.register_component("plain_dep") do
      "built"
    end

    @manager.reconcile_all
    assert_equal :active, @manager.fibers["plain_dep"]&.state
    assert_equal [], @manager.fibers["plain_dep"].requires
  end

  # ── Reentrant reconcile guard ────────────────────────────────────────

  # A factory that re-provides its own dependency while pending would
  # recurse through reconcile_all → activate! → factory → provide → …
  # without a reentrancy guard (Monitor is reentrant, so no deadlock —
  # it would spiral to SystemStackError instead).
  def test_pending_factory_reproviding_own_dependency_terminates
    runs = 0
    @manager.register_component("self_provider", inject: ["llm"]) do |ctx|
      runs += 1
      @manager.provide(:llm_client, "v#{runs}")
      ctx.require(:llm)
    end

    @manager.provide(:llm_client, "v1")

    assert_equal 1, runs, "activation must run the factory exactly once despite the nested re-provide"
    assert_equal :active, @manager.fibers["self_provider"]&.state
  end

  # Same hazard on the :active reactivation path (alias or canonical match):
  # reactivate! → factory → provide → reconcile → reactivate! → …
  def test_active_factory_reproviding_own_dependency_terminates
    runs = 0
    @manager.register_component("swap_self", inject: ["llm"]) do |ctx|
      runs += 1
      @manager.provide(:llm_client, "v#{runs + 10}") if runs > 1
      ctx.require(:llm)
    end

    @manager.provide(:llm_client, "v1")
    @manager.provide(:llm_client, "v2")

    assert_equal 2, runs, "reactivation must not re-enter itself through the nested re-provide"
    assert_equal :active, @manager.fibers["swap_self"]&.state
  end
end
