# frozen_string_literal: true

require_relative "../test_helper"

# Bounded tool execution (tools.call_timeout): the dispatch seam wraps the
# tool call in a budget; off stays byte-identical; a fired budget returns an
# honest error Result and the turn continues.
class TestToolCallTimeout < Minitest::Test
  class ConfigDouble
    def initialize(data = {})
      @data = data
    end

    def fetch(key, default = nil)
      @data.key?(key) ? @data[key] : default
    end
  end

  class ShellDouble
    attr_reader :config

    def initialize(config)
      @config = config
    end
  end

  class BusRecorder
    attr_reader :posts

    def initialize
      @posts = []
    end

    def post(name, payload = {}, **opts)
      @posts << [name, payload, opts]
      true
    end
  end

  class CtxDouble
    def initialize(bus)
      @bus = bus
    end

    def get(_key)
      @bus
    end
  end

  class RmDouble
    def initialize(ctx)
      @ctx = ctx
    end

    def context
      @ctx
    end
  end

  # StepExecutor deps double: shell + config + optional runtime_manager.
  class LoopDouble
    attr_accessor :step_count, :max_steps, :history, :invalid_tool_count, :total_tokens,
                  :last_turn_streamed, :buffer_manager, :shell, :lsp_manager, :tool_registry,
                  :config, :runtime_manager

    def initialize(config_data: {}, runtime: nil)
      @step_count = 1
      @max_steps = 10
      @history = []
      @invalid_tool_count = 0
      @total_tokens = 0
      @last_turn_streamed = false
      @buffer_manager = nil
      @lsp_manager = nil
      @config = ConfigDouble.new(config_data)
      @shell = ShellDouble.new(@config)
      @tool_registry = nil
      @runtime_manager = runtime
    end

    def on_step
      @on_step ||= ->(_evt) {}
    end
  end

  class SleepTool < Rubik::Tools::BaseTool
    def initialize(seconds:, name: "slow_tool", payload: "done")
      super(name: name, description: "sleeps then answers", risk: :read, params_schema: {})
      @seconds = seconds
      @payload = payload
    end

    def execute(_args = {})
      sleep(@seconds)
      @payload
    end
  end

  class RaisingTool < Rubik::Tools::BaseTool
    def initialize
      super(name: "raising_tool", description: "raises", risk: :read, params_schema: {})
    end

    def execute(_args = {})
      raise ArgumentError, "boom from tool"
    end
  end

  class ThreadProbeTool < Rubik::Tools::BaseTool
    attr_reader :thread_id

    def initialize
      super(name: "thread_probe_tool", description: "captures thread", risk: :read, params_schema: {})
    end

    def execute(_args = {})
      @thread_id = Thread.current.object_id
      "ok"
    end
  end

  def setup
    @saved_env = ENV.fetch("RUBIK_TOOLS_CALL_TIMEOUT", nil)
    ENV.delete("RUBIK_TOOLS_CALL_TIMEOUT")
  end

  def teardown
    if @saved_env.nil?
      ENV.delete("RUBIK_TOOLS_CALL_TIMEOUT")
    else
      ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = @saved_env
    end
  end

  def run_tool(tool, config_data: {}, runtime: nil)
    loop_inst = LoopDouble.new(config_data: config_data, runtime: runtime)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)
    result = executor.execute_registered_tool(tool, tool.name, {}, "c1", "never")
    [result, loop_inst]
  end

  def test_timeout_fires_honest_error_within_budget_and_turn_continues
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res, = run_tool(SleepTool.new(seconds: 2.0), config_data: { "tools.call_timeout" => 0.3 })
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator wall, :<, 1.5, "the budget bounds the step, not the tool's own runtime"
    assert_equal :error, res.status
    assert res.metadata["timed_out"]
    assert_equal 0.3, res.metadata["budget_seconds"]
    assert_includes res.output, "slow_tool"
    assert_includes res.output, "timed out"
    assert_includes res.output, "abandoned"
    assert_includes res.output, "narrower scope"
  end

  def test_knob_unset_runs_inline_on_the_caller_thread
    probe = ThreadProbeTool.new
    res, = run_tool(probe)

    assert_equal :ok, res.status
    assert_equal Thread.current.object_id, probe.thread_id, "no worker thread when the knob is off"

    probe2 = ThreadProbeTool.new
    res2, = run_tool(probe2, config_data: { "tools.call_timeout" => nil })
    assert_equal :ok, res2.status
    assert_equal Thread.current.object_id, probe2.thread_id
  end

  def test_override_relaxes_and_tightens_the_budget
    res, = run_tool(SleepTool.new(seconds: 0.5),
                    config_data: { "tools.call_timeout" => 0.1,
                                   "tools.call_timeout_overrides" => { "slow_tool" => 5 } })
    assert_equal :ok, res.status
    assert_equal "done", res.to_s

    res2, = run_tool(SleepTool.new(seconds: 5.0),
                     config_data: { "tools.call_timeout" => 30,
                                    "tools.call_timeout_overrides" => { "slow_tool" => 0.2 } })
    assert_equal :error, res2.status
    assert res2.metadata["timed_out"]
    assert_equal 0.2, res2.metadata["budget_seconds"]
  end

  def test_override_zero_disables_the_budget_for_that_tool
    res, = run_tool(SleepTool.new(seconds: 0.4),
                    config_data: { "tools.call_timeout" => 0.1,
                                   "tools.call_timeout_overrides" => { "slow_tool" => 0 } })
    assert_equal :ok, res.status
    assert_equal "done", res.to_s
  end

  def test_env_override_sets_and_disables_the_budget
    ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "0.3"
    res, = run_tool(SleepTool.new(seconds: 2.0), config_data: { "tools.call_timeout" => 30 })
    assert_equal :error, res.status

    ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "0"
    res2, = run_tool(SleepTool.new(seconds: 0.4), config_data: { "tools.call_timeout" => 0.2 })
    assert_equal :ok, res2.status, "env 0 explicitly disables despite the config budget"
  end

  def test_env_garbage_falls_back_to_config
    warnings = []
    Rubik::Log.stub(:warn, ->(channel, msg) { warnings << [channel, msg] }) do
      ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "garbage"
      probe = ThreadProbeTool.new
      res, = run_tool(probe, config_data: { "tools.call_timeout" => nil })

      assert_equal :ok, res.status
      assert_equal Thread.current.object_id, probe.thread_id
    end
    assert(warnings.any? { |(_ch, msg)| msg.include?("RUBIK_TOOLS_CALL_TIMEOUT") })
  end

  def test_invalid_config_value_warns_and_stays_off
    warnings = []
    Rubik::Log.stub(:warn, ->(channel, msg) { warnings << [channel, msg] }) do
      probe = ThreadProbeTool.new
      res, = run_tool(probe, config_data: { "tools.call_timeout" => -1 })

      assert_equal :ok, res.status
      assert_equal Thread.current.object_id, probe.thread_id
    end
    assert(warnings.any? { |(_ch, msg)| msg.include?("tools.call_timeout") })
  end

  def test_timeout_posts_the_observability_event
    bus = BusRecorder.new
    rm = RmDouble.new(CtxDouble.new(bus))
    run_tool(SleepTool.new(seconds: 2.0), config_data: { "tools.call_timeout" => 0.2 }, runtime: rm)

    entry = bus.posts.find { |(name, _p, _o)| name == :tool_call_timeout }
    refute_nil entry, "the timeout must reach the event bus (dmesg door)"
    _name, payload, opts = entry
    assert_equal({ tool: "slow_tool" }, payload)
    assert_equal :tools, opts[:subsystem]
    assert_equal :warn, opts[:level]
    assert_equal 0.2, opts[:budget_seconds]
  end

  def test_timeout_without_a_bus_logs_instead
    warnings = []
    Rubik::Log.stub(:warn, ->(channel, msg) { warnings << [channel, msg] }) do
      run_tool(SleepTool.new(seconds: 2.0), config_data: { "tools.call_timeout" => 0.2 })
    end
    assert(warnings.any? { |(ch, msg)| ch == :tools && msg.include?("slow_tool") })
  end

  def test_timeout_recorded_as_error_history_row
    _res, loop_inst = run_tool(SleepTool.new(seconds: 2.0), config_data: { "tools.call_timeout" => 0.2 })

    row = loop_inst.history.last
    refute_nil row
    assert_equal :error, row[:status]
    assert_operator row[:duration_ms].to_f, :>, 0
  end

  def test_raising_tool_keeps_normal_error_shape_under_wrap
    res, = run_tool(RaisingTool.new, config_data: { "tools.call_timeout" => 5 })

    assert_equal :error, res.status
    assert_includes res.output, "Error executing tool 'raising_tool'"
    assert_includes res.output, "ArgumentError"
    assert_nil res.metadata["timed_out"], "a raise is not a timeout"
  end

  def test_timeouts_feed_the_circuit_breaker
    # One executor (and thus one breaker) across both calls: the timeout is
    # recorded as a failure and the second call short-circuits.
    loop_inst = LoopDouble.new(config_data: { "tools.call_timeout" => 0.1,
                                              "tools.circuit_breaker" => { "enabled" => true, "threshold" => 1, "cooldown_seconds" => 60 } })
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)
    tool = SleepTool.new(seconds: 2.0)

    res1 = executor.execute_registered_tool(tool, tool.name, {}, "c1", "never")
    assert_equal :error, res1.status
    assert res1.metadata["timed_out"]

    res2 = executor.execute_registered_tool(tool, tool.name, {}, "c2", "never")
    assert_equal :error, res2.status
    assert_includes res2.output, "circuit open", "the second call short-circuits instead of running"
    assert_nil res2.metadata&.dig("timed_out"), "a circuit-open refusal is not a timeout"
  end

  def test_env_budget_is_refined_by_per_tool_overrides
    ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "0.2"
    res, = run_tool(SleepTool.new(seconds: 0.6),
                    config_data: { "tools.call_timeout_overrides" => { "slow_tool" => 5 } })
    assert_equal :ok, res.status, "the override refines the env-set global"

    ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "0"
    res2, = run_tool(SleepTool.new(seconds: 0.6),
                     config_data: { "tools.call_timeout_overrides" => { "slow_tool" => 5 } })
    assert_equal :ok, res2.status, "an explicit env disable wins over per-tool overrides"
  end

  def test_false_override_disables_the_budget_for_that_tool
    res, = run_tool(SleepTool.new(seconds: 0.4),
                    config_data: { "tools.call_timeout" => 0.1,
                                   "tools.call_timeout_overrides" => { "slow_tool" => false } })
    assert_equal :ok, res.status, "a false override must survive the truthiness lookup"
    assert_equal "done", res.to_s
  end

  def test_non_finite_budget_values_are_rejected
    warnings = []
    Rubik::Log.stub(:warn, ->(channel, msg) { warnings << [channel, msg] }) do
      ENV["RUBIK_TOOLS_CALL_TIMEOUT"] = "Infinity"
      probe = ThreadProbeTool.new
      res, = run_tool(probe)
      assert_equal :ok, res.status, "an infinite budget must not block the turn forever"
      assert_equal Thread.current.object_id, probe.thread_id
    end
    assert(warnings.any? { |(_ch, msg)| msg.include?("RUBIK_TOOLS_CALL_TIMEOUT") })
  ensure
    ENV.delete("RUBIK_TOOLS_CALL_TIMEOUT")
  end

  # --- Subagent plane seam ---

  class DispatchHost
    include Rubik::Orchestrator::Subagent::ToolDispatch

    def initialize(config, context)
      @config = config
      @context = context
    end
  end

  def test_subagent_dispatch_times_out_with_error_result
    bus = BusRecorder.new
    host = DispatchHost.new(ConfigDouble.new({ "tools.call_timeout" => 0.2 }), CtxDouble.new(bus))
    res = host.dispatch_subagent_tool(SleepTool.new(seconds: 2.0), "slow_tool", {})

    assert_equal :error, res.status
    assert res.metadata["timed_out"]
    assert_includes res.output, "timed out"
    refute_nil(bus.posts.find { |(name, _p, _o)| name == :tool_call_timeout })
  end

  def test_subagent_dispatch_unset_budget_runs_inline
    host = DispatchHost.new(ConfigDouble.new({}), nil)
    tool = SleepTool.new(seconds: 0.0)

    res = host.dispatch_subagent_tool(tool, "slow_tool", {})

    assert_equal :ok, res.status
    assert_equal "done", res.to_s
  end
end
