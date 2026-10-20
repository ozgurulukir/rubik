# frozen_string_literal: true

require_relative "../test_helper"

# G19: opt-in tool execution circuit breaker. Default config is disabled —
# the loop's synchronous execution is by design; the breaker only stops
# repeated futile calls once enabled.
class TestToolCircuitBreaker < Minitest::Test
  def setup
    @breaker = Rubik::Orchestrator::ToolCircuitBreaker.new(threshold: 3, cooldown_seconds: 0.05)
  end

  def test_starts_closed_and_opens_after_consecutive_failures
    assert_equal :closed, @breaker.state("web")
    assert @breaker.allow?("web")

    2.times { @breaker.record_failure("web") }
    assert_equal :closed, @breaker.state("web")
    assert @breaker.allow?("web")

    @breaker.record_failure("web")
    assert_equal :open, @breaker.state("web")
    refute @breaker.allow?("web"), "open circuit must short-circuit"
  end

  def test_other_tools_keep_their_own_circuit
    3.times { @breaker.record_failure("web") }
    refute @breaker.allow?("web")
    assert @breaker.allow?("files"), "per-tool isolation"
  end

  def test_success_resets_the_count
    2.times { @breaker.record_failure("web") }
    @breaker.record_success("web")
    2.times { @breaker.record_failure("web") }
    assert_equal :closed, @breaker.state("web"), "count must reset on success, not accumulate"
  end

  def test_cooldown_elapsed_allows_one_probe_then_reopens_on_failure
    3.times { @breaker.record_failure("web") }
    sleep 0.06 # cooldown 0.05s

    assert @breaker.allow?("web"), "cooldown elapsed -> half-open probe"
    @breaker.record_failure("web")
    refute @breaker.allow?("web"), "failed probe -> reopened for another cooldown"
  end

  def test_half_open_gate_blocks_subsequent_calls_while_probe_in_flight
    3.times { @breaker.record_failure("web") }
    sleep 0.06

    assert @breaker.allow?("web"), "first call in half-open state gets the probe token"
    refute @breaker.allow?("web"), "subsequent call while probe is in flight must be blocked"
    refute @breaker.allow?("web"), "third call while probe is in flight must also be blocked"
  end

  def test_half_open_state_does_not_raise_argument_error
    3.times { @breaker.record_failure("web") }
    sleep 0.06

    @breaker.allow?("web") # transitions to half-open and consumes token
    # Checking allow? again on half-open circuit with probing=false must return false without ArgumentError
    refute_nil @breaker.allow?("web")
    refute @breaker.allow?("web")
  end

  def test_successful_probe_closes_the_circuit
    3.times { @breaker.record_failure("web") }
    sleep 0.06

    assert @breaker.allow?("web")
    @breaker.record_success("web")
    assert_equal :closed, @breaker.state("web")
    assert @breaker.allow?("web")
  end

  # ── StepExecutor wiring ────────────────────────────────────────────────

  class FlakyTool < Rubik::Tools::BaseTool
    def initialize(fail_times)
      super(name: "flaky", description: "wedged", risk: :read, params_schema: {})
      @left = fail_times
    end

    def execute(_args)
      raise "wedged backend" if @left.positive?

      @left -= 1
      "ok output"
    end
  end

  class BreakerLoop
    attr_accessor :step_count, :max_steps, :history, :invalid_tool_count, :total_tokens,
                  :last_turn_streamed, :buffer_manager, :shell, :lsp_manager,
                  :tool_registry, :config

    def initialize(registry, config)
      @step_count = 1
      @max_steps = 10
      @history = []
      @invalid_tool_count = 0
      @total_tokens = 0
      @last_turn_streamed = false
      @buffer_manager = nil
      @shell = nil
      @lsp_manager = nil
      @tool_registry = registry
      @config = config
    end

    def on_step
      @events ||= []
      ->(evt) { @events << evt }
    end
  end

  def test_disabled_by_default_tools_run_normally
    registry = Rubik::Tools::Registry.new
    registry.register(FlakyTool.new(0))
    loop_double = BreakerLoop.new(registry, nil)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_double)

    5.times { executor.execute_single_tool_call({ "tool" => "flaky", "args" => {}, "id" => "c1" }, "") }

    assert_nil executor.instance_variable_get(:@circuit_breaker), "no breaker without config"
    assert_equal(5, loop_double.history.count { |h| h[:status] == :ok })
  end

  def test_enabled_breaker_short_circuits_wedged_tool
    registry = Rubik::Tools::Registry.new
    registry.register(FlakyTool.new(99))
    config = { "tools.circuit_breaker" => { "enabled" => true, "threshold" => 2, "cooldown_seconds" => 60 } }
    loop_double = BreakerLoop.new(registry, config)
    # The breaker config is read through the loop's shell (ShellDeps surface);
    # without a shell double the breaker silently never engages.
    shell = Object.new
    shell.define_singleton_method(:config) { config }
    loop_double.shell = shell
    executor = Rubik::Orchestrator::StepExecutor.new(loop_double)

    call = { "tool" => "flaky", "args" => {}, "id" => "c1" }
    2.times { executor.execute_single_tool_call(call, "") }
    executor.execute_single_tool_call(call, "")

    last = loop_double.history.last
    assert_equal :error, last[:status]
    assert_includes last[:content], "circuit open",
                    "the third call must be blocked by the breaker before reaching the backend"
    refute last[:content].include?("wedged backend"),
           "open circuit must not execute the tool again"
  end
end
