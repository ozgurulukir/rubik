# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/auto_apply"

class TestAutoApplyPolicy < Minitest::Test
  AA = Rubik::Orchestrator::AutoApply

  def setup
    @temp_root = Dir.mktmpdir("rubik_aa_root")
    @temp_home = Dir.mktmpdir("rubik_aa_home")
  end

  def teardown
    remove_temp_dir(@temp_root)
    remove_temp_dir(@temp_home)
  end

  # -- decision table: main path (mode only) ----------------------------

  def test_main_path_mode_table_per_trigger
    manual = { "buffer.auto_apply" => "manual" }
    on_test = { "buffer.auto_apply" => "on_test" }
    on_finish = { "buffer.auto_apply" => "on_finish" }
    always = { "buffer.auto_apply" => "always" }

    # pre_execution: on_test / always, test-class tools only
    assert AA.apply?(on_test, trigger: :pre_execution, tool: "run_tests")
    assert AA.apply?(always, trigger: :pre_execution, tool: "lint")
    refute AA.apply?(manual, trigger: :pre_execution, tool: "run_tests")
    refute AA.apply?(on_finish, trigger: :pre_execution, tool: "run_tests")
    # tool classification
    refute AA.apply?(on_test, trigger: :pre_execution, tool: "write_file")
    assert AA.apply?(on_test, trigger: :pre_execution, tool: nil),
           "nil tool = caller established the test-class context (REPL !test/!sh)"

    # finish: on_finish / on_test / always (on_test fires at finish on
    # purpose — the mode ladder ends every turn flushed)
    assert AA.apply?(on_finish, trigger: :finish)
    assert AA.apply?(on_test, trigger: :finish)
    assert AA.apply?(always, trigger: :finish)
    refute AA.apply?(manual, trigger: :finish)

    # post_tool: always only
    assert AA.apply?(always, trigger: :post_tool)
    refute AA.apply?(on_test, trigger: :post_tool)
    refute AA.apply?(on_finish, trigger: :post_tool)
  end

  def test_subagent_flag_composition
    flag_on = { "subagents.auto_apply_buffer" => true, "buffer.auto_apply" => "manual" }
    # Flag on enables every trigger even in manual mode
    assert AA.apply?(flag_on, trigger: :pre_execution, subagent: true, tool: "run_tests")
    assert AA.apply?(flag_on, trigger: :finish, subagent: true)
    assert AA.apply?(flag_on, trigger: :post_tool, subagent: true)

    # Flag off falls back to the mode per trigger (the reconciliation:
    # supervisor completion and subagent finish now honor on_finish)
    flag_off = { "subagents.auto_apply_buffer" => false, "buffer.auto_apply" => "on_finish" }
    assert AA.apply?(flag_off, trigger: :finish, subagent: true)
    assert AA.apply?(flag_off, trigger: :completion, subagent: true)
    refute AA.apply?(flag_off, trigger: :pre_execution, subagent: true, tool: "run_tests")
    refute AA.apply?(flag_off, trigger: :post_tool, subagent: true)

    # Flag off + manual: nothing fires
    both_off = { "subagents.auto_apply_buffer" => false, "buffer.auto_apply" => "manual" }
    refute AA.apply?(both_off, trigger: :finish, subagent: true)
    refute AA.apply?(both_off, trigger: :pre_execution, subagent: true, tool: "run_tests")
  end

  def test_main_path_ignores_subagent_flag
    config = { "subagents.auto_apply_buffer" => true, "buffer.auto_apply" => "manual" }
    refute AA.apply?(config, trigger: :pre_execution, tool: "run_tests")
    refute AA.apply?(config, trigger: :finish)
    refute AA.apply?(config, trigger: :post_tool),
           "the subagents flag must never gate the main loop"
  end

  # -- defensive config reads -------------------------------------------

  def test_mode_defensive_spellings
    assert_equal "manual", AA.mode(nil)
    assert_equal "manual", AA.mode({})
    assert_equal "on_test", AA.mode({ "buffer.auto_apply" => "on_test" })
    assert_equal "on_test", AA.mode({ "buffer.auto_apply" => "ON_TEST" }),
                 "mode is normalized case-insensitively"

    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    config.set("buffer.auto_apply", "on_finish")
    assert_equal "on_finish", AA.mode(config)
  end

  def test_subagent_flag_strict_boolean
    assert AA.subagent_flag_on?({ "subagents.auto_apply_buffer" => true })
    refute AA.subagent_flag_on?({ "subagents.auto_apply_buffer" => false })
    refute AA.subagent_flag_on?({ "subagents.auto_apply_buffer" => "true" }),
           "a YAML 'true' string stays off (strict == true, historical semantics)"
    refute AA.subagent_flag_on?({})
    refute AA.subagent_flag_on?(nil)
  end

  def test_mode_default_aligns_with_config_defaults
    assert_equal Rubik::Config::Defaults::DEFAULT_CONFIG.dig("buffer", "auto_apply"), AA::DEFAULT_MODE
  end

  def test_defensive_subagent_flag_default_diverges_from_yaml_by_design
    # defaults.rb ships true (production wiring always passes a real
    # Config), but a config-less host must read OFF so a nil-config
    # Supervisor never writes disk (merge-without-apply pin,
    # test_subagent_orchestration.rb). Do not "unify" these.
    assert_equal true, Rubik::Config::Defaults::DEFAULT_CONFIG.dig("subagents", "auto_apply_buffer")
    assert_equal false, AA::DEFAULT_FLAG
  end

  def test_test_class_tool_vocabulary
    ["run_command", "run_tests", "test", "lint"].each { |t| assert AA.test_class_tool?(t), t }
    refute AA.test_class_tool?("write_file")
    refute AA.test_class_tool?("finish")
    refute AA.test_class_tool?(nil)
  end

  def test_fires_pure_predicate_is_the_injection_seam
    assert AA.fires?("on_finish", :finish)
    assert AA.fires?("Always", :post_tool)
    refute AA.fires?("never", :finish)
    refute AA.fires?("manual", :post_tool)
    error = assert_raises(KeyError) { AA.fires?("always", :typo) }
    assert_match(/typo|key/, error.message, "an unknown trigger fails loud, not silently false")
  end

  # -- canonical effect --------------------------------------------------

  def test_apply_and_sync_applies_and_syncs_when_dirty
    buffer = dirty_buffer(["a.rb", "b.rb"])
    synced = []
    shell = sync_spy(synced)

    applied = AA.apply_and_sync(buffer, shell)

    assert_equal ["a.rb", "b.rb"], applied
    assert_equal ["a.rb", "b.rb"], synced
  end

  def test_apply_and_sync_no_op_when_clean
    applied_calls = []
    buffer = Object.new
    buffer.define_singleton_method(:dirty?) { false }
    buffer.define_singleton_method(:apply!) { applied_calls << :apply! }

    assert_equal [], AA.apply_and_sync(buffer, nil)
    assert_empty applied_calls, "a clean buffer must never reach apply!"
  end

  def test_apply_and_sync_skips_sync_on_empty_apply
    synced = []
    buffer = dirty_buffer([])

    assert_equal [], AA.apply_and_sync(buffer, sync_spy(synced))
    assert_empty synced, "an empty apply skips the sync (supervisor precedent)"
  end

  def test_apply_and_sync_propagates_apply_errors
    buffer = dirty_buffer(nil) # apply! raises (see helper)
    assert_raises(RuntimeError) { AA.apply_and_sync(buffer, nil) }
  end

  # -- failure channel ---------------------------------------------------

  def test_report_failure_emits_the_notice_event
    events = []
    bus = Object.new
    bus.define_singleton_method(:emit) { |name, payload| events << [name, payload] }

    AA.report_failure(bus, id: "subagent-1", role: "Coder", state: :completed,
                           trigger: :completion, error: RuntimeError.new("disk full"))

    assert_equal 1, events.size
    assert_equal Rubik::Orchestrator::Subagent::Notices::AUTO_APPLY_FAILED_EVENT, events.first[0]
    payload = events.first[1]
    assert_equal "subagent-1", payload[:id]
    assert_equal "completed", payload[:state]
    assert_equal "completion: RuntimeError: disk full", payload[:reason]
  end

  def test_report_failure_tolerates_missing_bus
    # No raise, no crash — the warn fallback keeps the failure visible on
    # stderr without a bus (assert only that it survives the call).
    AA.report_failure(nil, id: "s", role: "R", state: :running,
                           trigger: :finish, error: RuntimeError.new("boom"))
    pass
  end

  # -- copy vocabulary ---------------------------------------------------

  def test_copy_vocabulary
    assert_equal "[Rubik::Buffer] Auto-applied 2 modified file(s) before test run.",
                 AA.applied_line(2, "test run")
    assert_equal "⚠️ [Rubik::Buffer] Notice: Unapplied buffer changes exist. Tests run against files on disk.",
                 AA.unapplied_warning("Tests")
  end

  # -- main-path wiring (StepExecutor) -----------------------------------

  def test_post_tool_auto_apply_emits_post_tool_notice
    events = []
    executor, tool = step_executor_spy(events, dirty_buffer(["staged.rb"]))

    res = executor.execute_registered_tool(tool, "noop_tool", {}, "c1", "always")

    assert_equal :ok, res.status
    auto_apply_event = events.find { |ev| ev[:type] == :auto_apply }
    refute_nil auto_apply_event, "always mode must make the post-tool disk write visible"
    assert_equal "post_tool", auto_apply_event[:reason]
    assert_equal ["staged.rb"], auto_apply_event[:files]
  end

  def test_post_tool_notice_stays_silent_below_always
    events = []
    executor, tool = step_executor_spy(events, dirty_buffer(["staged.rb"]))

    executor.execute_registered_tool(tool, "noop_tool", {}, "c1", "on_test")

    assert_nil(events.find { |ev| ev[:type] == :auto_apply })
  end

  private

  # A StepExecutor over a minimal duck-typed Loop (the test_tools_elm
  # pattern): registered no-op tool, dirty buffer double, on_step spy.
  def step_executor_spy(events, buffer)
    tool = Object.new
    tool.define_singleton_method(:name) { "noop_tool" }
    tool.define_singleton_method(:execute) { |_args| Rubik::Tools::Result.new(tool_name: "noop_tool", status: :ok, output: "done") }
    registry = Rubik::Tools::Registry.new
    registry.register(tool)

    loop_mock = Object.new
    loop_mock.define_singleton_method(:tool_registry) { registry }
    loop_mock.define_singleton_method(:buffer_manager) { buffer }
    loop_mock.define_singleton_method(:shell) { nil }
    loop_mock.define_singleton_method(:lsp_manager) { nil }
    loop_mock.define_singleton_method(:on_step) { ->(ev) { events << ev } }
    invalid_count = 0
    loop_mock.define_singleton_method(:invalid_tool_count) { invalid_count }
    loop_mock.define_singleton_method(:invalid_tool_count=) { |v| invalid_count = v }
    history = []
    loop_mock.define_singleton_method(:history) { history }
    loop_mock.define_singleton_method(:step_count) { 1 }
    loop_mock.define_singleton_method(:max_steps) { 40 }
    loop_mock.define_singleton_method(:total_tokens) { 0 }

    [Rubik::Orchestrator::StepExecutor.new(loop_mock), tool]
  end

  def dirty_buffer(applied)
    buffer = Object.new
    buffer.define_singleton_method(:dirty?) { true }
    if applied.nil?
      buffer.define_singleton_method(:apply!) { raise "simulated apply failure" }
    else
      buffer.define_singleton_method(:apply!) { applied }
    end
    buffer
  end

  def sync_spy(synced)
    shell = Object.new
    shell.define_singleton_method(:sync_context_and_ast) { |files| synced.concat(files) }
    shell
  end
end
