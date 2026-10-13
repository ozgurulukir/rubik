# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/runtime"
require_relative "../../lib/rubik/runtime/manager"

class TestInspectRuntimeTool < Minitest::Test
  def setup
    @runtime_manager = Rubik::Runtime::Manager.new
    @tool_registry = Object.new
    @shell = Object.new
    @tool = Rubik::Tools::InspectRuntimeTool.new(@runtime_manager, @tool_registry, @shell)
  end

  def teardown
    @runtime_manager&.dispose!
  end

  # =========================================================================
  # Metadata & Schema
  # =========================================================================

  def test_declaration_and_metadata
    assert_equal "inspect_runtime", @tool.name
    assert_equal :read, @tool.risk
    assert_includes @tool.aliases, "runtime_status"
    assert_includes @tool.aliases, "inspect_fibers"

    schema = @tool.params_schema
    assert_equal "object", schema[:type]
    assert_equal ["all", "fibers", "services", "tools", "commands", "tasks"], schema[:properties][:target][:enum]
  end

  # =========================================================================
  # Nil Dependency Resilience
  # =========================================================================

  def test_execute_with_nil_dependencies
    empty_tool = Rubik::Tools::InspectRuntimeTool.new(nil, nil, nil)
    out = empty_tool.execute("target" => "all")

    assert_equal "=== Rubik Spatiotemporal Runtime Diagnostics ===", out.to_s
  end

  # =========================================================================
  # Services Inspection
  # =========================================================================

  def test_inspect_services
    @runtime_manager.provide("database", "mock_db_instance")
    @runtime_manager.provide("llm_client", "mock_llm")

    out = @tool.execute("target" => "services")

    assert_includes out, "=== Rubik Spatiotemporal Runtime Diagnostics ==="
    assert_includes out, "[Services / Coeffects Active (2)]:"
    assert_includes out, "• database     -> String"
    assert_includes out, "• llm_client   -> String"
    assert_includes out, "(LIFO Accumulator Depth:"
  end

  # =========================================================================
  # Fibers Inspection
  # =========================================================================

  def test_inspect_fibers_active_pending_failed
    @runtime_manager.provide("db", "connected")

    # Active fiber (all dependencies satisfied)
    @runtime_manager.register_component("active_fiber", inject: ["db"]) { |ctx, _cfg| }

    # Pending fiber (missing dependency 'redis')
    @runtime_manager.register_component("pending_fiber", inject: ["db", "redis"]) { |ctx, _cfg| }

    # Failed fiber (raises error during activation)
    @runtime_manager.register_component("failing_fiber", inject: ["db"]) do |_ctx, _cfg|
      raise "boom during fiber startup"
    end

    out = @tool.execute("target" => "fibers")

    assert_includes out, "[Fibers (1 Active, 1 Pending, 1 Failed)]:"
    assert_includes out, "🟢 ACTIVE : active_fiber (injects: db)"
    assert_includes out, "⏳ PENDING: pending_fiber (waiting on: redis)"
    assert_includes out, "🔴 FAILED : failing_fiber (error: boom during fiber startup)"
  end

  # =========================================================================
  # Tools Inspection
  # =========================================================================

  def test_inspect_tools
    mock_tool = Struct.new(:name, :risk, :description).new("grep_search", :read, "Search for regex pattern across files in directory")

    def @tool_registry.list
      [Struct.new(:name, :risk, :description).new("grep_search", :read, "Search for regex pattern across files in directory")]
    end

    out = @tool.execute("target" => "tools")

    assert_includes out, "[Tool Registry (1 Registered Tools)]:"
    assert_includes out, "⚙ grep_search            [read] - Search for regex pattern across files in directory"
  end

  # =========================================================================
  # Commands Inspection
  # =========================================================================

  def test_inspect_commands
    def @shell.commands
      {
        "help" => { description: "Show available REPL commands" },
        "clear" => { description: "Clear conversation screen" }
      }
    end

    out = @tool.execute("target" => "commands")

    assert_includes out, "[REPL Bang Commands (2 Registered)]:"
    assert_includes out, "!clear            : Clear conversation screen"
    assert_includes out, "!help             : Show available REPL commands"
  end

  # =========================================================================
  # Tasks Inspection
  # =========================================================================

  def test_inspect_tasks_empty
    mock_task_mgr = Object.new
    def mock_task_mgr.list; []; end

    @runtime_manager.provide(Rubik::Coeffects::TASK_MANAGER, mock_task_mgr)

    out = @tool.execute("target" => "tasks")

    assert_includes out, "[Background Tasks (0 Tracked)]:"
    assert_includes out, "(none)"
  end

  def test_inspect_tasks_running_and_completed
    running_task = Struct.new(:id, :status, :pid, :command, :running?, :uptime).new(
      "task-1", :running, 1234, "ruby server.rb", true, 5.234
    )
    completed_task = Struct.new(:id, :status, :pid, :command, :running?, :exit_code).new(
      "task-2", :completed, 1235, "rake build", false, 0
    )

    mock_task_mgr = Object.new
    mock_task_mgr.define_singleton_method(:list) { [running_task, completed_task] }

    @runtime_manager.provide(Rubik::Coeffects::TASK_MANAGER, mock_task_mgr)

    out = @tool.execute("target" => "tasks")

    assert_includes out, "[Background Tasks (2 Tracked)]:"
    assert_includes out, "• [task-1] RUNNING (PID 1234, up 5.2s): ruby server.rb"
    assert_includes out, "• [task-2] COMPLETED (PID 1235, completed (exit 0)): rake build"
  end

  def test_inspect_tasks_fallback_to_shell_task_manager
    mock_task_mgr = Object.new
    def mock_task_mgr.list; []; end

    def @shell.task_manager
      @tm ||= begin
        tm = Object.new
        def tm.list; []; end
        tm
      end
    end

    out = @tool.execute("target" => "tasks")

    assert_includes out, "[Background Tasks (0 Tracked)]:"
  end

  # =========================================================================
  # All Target & Argument Formats
  # =========================================================================

  def test_inspect_all_renders_all_components
    @runtime_manager.provide("logger", "active_logger")

    def @tool_registry.list; []; end
    def @shell.commands; {}; end

    mock_task_mgr = Object.new
    def mock_task_mgr.list; []; end
    @runtime_manager.provide(Rubik::Coeffects::TASK_MANAGER, mock_task_mgr)

    out = @tool.execute("target" => "all")

    assert_includes out, "[Services / Coeffects Active (2)]:"
    assert_includes out, "[Fibers (0 Active, 0 Pending, 0 Failed)]:"
    assert_includes out, "[Tool Registry (0 Registered Tools)]:"
    assert_includes out, "[REPL Bang Commands (0 Registered)]:"
    assert_includes out, "[Background Tasks (0 Tracked)]:"
  end

  def test_target_accepts_symbols_and_uppercase_strings
    @runtime_manager.provide("service1", "val1")

    out_sym = @tool.execute(target: :services)
    assert_includes out_sym, "[Services / Coeffects Active (1)]:"

    out_upper = @tool.execute("target" => "SERVICES")
    assert_includes out_upper, "[Services / Coeffects Active (1)]:"
  end
end
