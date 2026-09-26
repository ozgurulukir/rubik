# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSpatiotemporalTeardownAndTopology < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_test_p106")
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  # =========================================================================
  # Faz A & D: Headless Teardown via ServiceCatalog & Composition
  # =========================================================================

  def test_headless_teardown_triggers_lsp_and_mcp_stop_all_via_service_catalog_build
    lsp_stopped = false
    mcp_stopped = false

    mock_lsp = Object.new
    mock_lsp.define_singleton_method(:stop_all) { lsp_stopped = true }

    mock_mcp = Object.new
    mock_mcp.define_singleton_method(:stop_all) { mcp_stopped = true }

    scope = Rubik::REPL::ServiceCatalog::Scope.new(
      root_dir: @temp_dir,
      overrides: {
        lsp_manager: mock_lsp,
        mcp_manager: mock_mcp
      }
    )

    built = Rubik::REPL::ServiceCatalog.build(scope)
    runtime_manager = built.fetch(:runtime_manager)

    refute lsp_stopped, "LSP stop_all must not be called before context disposal"
    refute mcp_stopped, "MCP stop_all must not be called before context disposal"

    # Pure headless teardown: only runtime_manager.context.dispose is invoked
    runtime_manager.context.dispose

    assert lsp_stopped, "LSP manager stop_all must be triggered by context disposal"
    assert mcp_stopped, "MCP manager stop_all must be triggered by context disposal"
  end

  def test_headless_teardown_via_composition_build_stops_all_services
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)

    lsp = parts.lsp_manager
    mcp = parts.mcp_manager
    dispatcher = parts.dispatcher
    init = parts.init

    refute dispatcher.stopped?, "Dispatcher should be alive before dispose"
    refute init.stopped?, "Init should be alive before dispose"

    # Execute pure headless context teardown
    parts.runtime_manager.context.dispose

    assert dispatcher.stopped?, "Dispatcher must be stopped on context dispose"
    assert init.stopped?, "Init must be stopped on context dispose"
    # LSP and MCP stop_all are idempotent and safe to call
    assert_silent { lsp.stop_all }
    assert_silent { mcp.stop_all }
  end

  def test_shell_stop_is_idempotent_and_safe_after_prior_context_dispose
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)
    shell = Rubik::REPL::Shell.new(output: StringIO.new, parts: parts)

    # First dispose context
    shell.runtime_manager.context.dispose

    # Subsequent Shell#stop must be an idempotent no-op without raising errors
    assert_silent do
      shell.stop
    end

    refute shell.running?
  end

  # =========================================================================
  # Faz B & D: Topolojik Fiber Sıralaması (reconcile_all)
  # =========================================================================

  def test_topological_sort_fibers_reconciles_in_dependency_dag_order
    manager = Rubik::Runtime::Manager.new
    activation_order = []

    # A depends on B, B depends on C, C is independent.
    # Register in REVERSE order: A, then B, then C.
    manager.register_component(:a, inject: [:b]) do
      activation_order << :a
      manager.provide(:a, "service_a")
    end

    manager.register_component(:b, inject: [:c]) do
      activation_order << :b
      manager.provide(:b, "service_b")
    end

    manager.register_component(:c) do
      activation_order << :c
      manager.provide(:c, "service_c")
    end

    # Manager#topological_sort_fibers directly tested
    fibers = manager.fibers.values
    sorted = manager.topological_sort_fibers(fibers)
    assert_equal ["c", "b", "a"], sorted.map(&:name), "Topological sort must order C -> B -> A"

    # Trigger reconcile_all
    manager.reconcile_all

    assert_equal [:c, :b, :a], activation_order, "Activation must strictly follow topological dependency order"
    assert_equal 3, manager.active_fibers.size, "All 3 fibers must be active"
  ensure
    manager&.dispose!
  end

  def test_topological_sort_with_explicit_provides_and_requires
    manager = Rubik::Runtime::Manager.new
    events = []

    # X requires "db" (provided by Y)
    # Y requires "config" (provided by Z)
    # Z provides "config"
    manager.register_component(:consumer_x, requires: ["db"]) do
      events << :x
      manager.provide("x_out", true)
    end

    manager.register_component(:provider_y, requires: ["config"], provides: ["db"]) do
      events << :y
      manager.provide("db", { connected: true })
    end

    manager.register_component(:root_z, provides: ["config"]) do
      events << :z
      manager.provide("config", { env: "test" })
    end

    manager.reconcile_all

    assert_equal [:z, :y, :x], events, "Must activate root_z -> provider_y -> consumer_x"
    assert_equal 3, manager.active_fibers.size
  ensure
    manager&.dispose!
  end

  def test_topological_sort_cycle_detection_isolates_and_marks_failed
    manager = Rubik::Runtime::Manager.new
    events = []

    # Independent fiber
    manager.register_component(:independent) do |sub_ctx|
      events << :independent
      sub_ctx.provide("indep", true)
    end

    # Mutual dependency cycle: cycle_a depends on cycle_b, cycle_b depends on cycle_a
    manager.register_component(:cycle_a, inject: ["cycle_b"]) do
      events << :cycle_a
    end

    manager.register_component(:cycle_b, inject: ["cycle_a"]) do
      events << :cycle_b
    end

    # System must not hang or deadlock
    manager.reconcile_all

    assert_includes events, :independent, "Independent fiber must activate despite other fibers being in a cycle"
    refute_includes events, :cycle_a, "Cycle fiber A must not activate"
    refute_includes events, :cycle_b, "Cycle fiber B must not activate"

    failed = manager.failed_fibers.map(&:name).sort
    assert_equal ["cycle_a", "cycle_b"], failed, "Fibers in a cycle must be marked :failed"
  ensure
    manager&.dispose!
  end

  # =========================================================================
  # Faz C & D: Dmesg Telemetrisi ile Bağlam Kapanışının Entegrasyonu
  # =========================================================================

  def test_dmesg_telemetry_records_context_dispose_lifecycle
    dmesg = Rubik::Kernel::Dmesg.new(capacity: 64)
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::DMESG, dmesg)

    # Register disposables
    cleanups = []
    ctx.on_dispose { cleanups << 1 }
    ctx.on_dispose { raise "simulated inverse failure" }
    ctx.on_dispose { cleanups << 3 }

    ctx.dispose

    records = dmesg.tail(10, subsystem: :context)
    refute_empty records, "Dmesg must contain records for subsystem :context"

    # 1. Beginning log
    begin_record = records.find { |r| r.message.include?("Beginning context dispose") }
    refute_nil begin_record, "Must log 'Beginning context dispose' to dmesg"
    assert_equal :info, begin_record.level
    # 3 custom inverses + 1 delete-inverse for dmesg
    assert_match(/with \d+ inverse\(s\)/, begin_record.message)

    # 2. Error log for failed inverse
    err_record = records.find { |r| r.level == :err && r.message.include?("Dispose inverse failed") }
    refute_nil err_record, "Must log 'Dispose inverse failed' at :err level"
    assert_includes err_record.message, "RuntimeError: simulated inverse failure"

    # 3. Complete log
    complete_record = records.find { |r| r.message.include?("Context dispose complete") }
    refute_nil complete_record, "Must log 'Context dispose complete' to dmesg"
    assert_equal :info, complete_record.level
    assert_match(/inverse\(s\) executed/, complete_record.message)

    assert_equal [3, 1], cleanups, "Cleanups must execute in LIFO order despite failure"
  end

  def test_dmesg_telemetry_records_cycle_error_in_runtime
    dmesg = Rubik::Kernel::Dmesg.new(capacity: 64)
    manager = Rubik::Runtime::Manager.new
    manager.context.provide(Rubik::Coeffects::DMESG, dmesg)

    manager.register_component(:cyclic_alpha, inject: ["cyclic_beta"]) { nil }
    manager.register_component(:cyclic_beta, inject: ["cyclic_alpha"]) { nil }

    manager.reconcile_all

    records = dmesg.tail(10, subsystem: :runtime, level: :err)
    refute_empty records, "Dmesg must contain error record for detected cycle"
    assert_includes records.first.message, "Dependency cycle detected among fibers"
  ensure
    manager&.dispose!
  end
end
