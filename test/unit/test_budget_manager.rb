# frozen_string_literal: true

require_relative "../test_helper"

class TestBudgetManager < Minitest::Test
  # Minimal stand-in for Rubik::Orchestrator::Loop carrying only the state
  # BudgetManager reads through accessors (step_count, max_steps, history,
  # total_tokens, context knobs, on_step callback).
  class MockLoop
    attr_accessor :step_count, :max_steps, :warn_at_ratio, :history, :total_tokens,
                  :context_warning_emitted, :context_limit, :max_output_tokens, :config, :on_step,
                  :runtime_manager

    def initialize(config: nil, context_limit: 32_768, max_output_tokens: 4_096)
      @step_count = 0
      @max_steps = 40
      @warn_at_ratio = 0.75
      @history = []
      @total_tokens = { input: 0, output: 0 }
      @context_warning_emitted = false
      @config = config
      @context_limit = context_limit
      @max_output_tokens = max_output_tokens
      @on_step = nil
    end
  end

  def setup
    @loop = MockLoop.new
    @manager = Rubik::Orchestrator::BudgetManager.new(@loop)
  end

  # ── evaluate_step_budget_warning! ──────────────────────────────────

  def test_warns_once_when_step_count_reaches_warn_threshold
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.step_count = 30 # 40 * 0.75 = 30
    @loop.max_steps = 40

    result = @manager.evaluate_step_budget_warning!(false)

    assert_equal true, result
    assert_equal 1, events.size
    assert_equal :step_warning, events.first[:type]
    assert_equal 30, events.first[:current]
    assert_equal 40, events.first[:max]
    assert_equal 10, events.first[:remaining]
    # Warning is appended as its own user message
    assert_equal 1, @loop.history.size
    assert_equal "user", @loop.history.first[:role]
    assert_includes @loop.history.first[:content], "<step_budget"
    assert_includes @loop.history.first[:content], "10 steps left"
  end

  def test_warn_returns_true_only_once
    @loop.step_count = 30
    @loop.max_steps = 40

    first = @manager.evaluate_step_budget_warning!(false)
    second = @manager.evaluate_step_budget_warning!(true) # already warned

    assert_equal true, first
    assert_equal true, second # warned flag short-circuits; returns warned as-is
    assert_equal 1, @loop.history.size # no duplicate message
  end

  def test_no_warning_below_threshold
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.step_count = 10

    result = @manager.evaluate_step_budget_warning!(false)

    refute result
    assert_empty events
    assert_empty @loop.history
  end

  def test_no_warning_at_or_above_max_steps
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.step_count = 40
    @loop.max_steps = 40

    result = @manager.evaluate_step_budget_warning!(false)

    refute result
    assert_empty events
  end

  def test_warning_uses_loop_warn_step_and_remaining_calculation
    @loop.step_count = 60
    @loop.max_steps = 80 # threshold: ceil(80 * 0.75) = 60

    @manager.evaluate_step_budget_warning!(false)

    assert_equal "<step_budget current=\"60\" max=\"80\" remaining=\"20\" " \
                 "alert=\"Step budget nearing limit (20 steps left). Please begin concluding your work, " \
                 "verify with tests/diagnostics, and call finish. If the task genuinely needs more room, you may " \
                 "raise the live step budget with exec_repl_command('!steps <n>') where n is the new total.\" />",
                 @loop.history.first[:content]
  end

  def test_warning_threshold_tracks_extended_max_steps
    @loop.step_count = 10
    @loop.max_steps = 40 # threshold: 30

    refute @manager.evaluate_step_budget_warning!(false)

    # Live `!steps <n>` extension raises the budget; the threshold must follow.
    @loop.max_steps = 100 # new threshold: 75
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.step_count = 50 # past the OLD threshold, below the NEW one

    refute @manager.evaluate_step_budget_warning!(false)
    assert_empty events

    @loop.step_count = 75
    assert @manager.evaluate_step_budget_warning!(false)
    assert_equal 25, events.first[:remaining]
  end

  def test_warning_fires_once_even_after_budget_extension
    @loop.step_count = 30
    @loop.max_steps = 40

    assert @manager.evaluate_step_budget_warning!(false)

    @loop.max_steps = 100
    @loop.step_count = 76
    assert_equal true, @manager.evaluate_step_budget_warning!(true) # latched
    assert_equal 1, @loop.history.size # no duplicate warning message
  end

  # ── evaluate_context_compaction! ───────────────────────────────────

  def test_no_compaction_when_context_limit_is_nil
    @loop.context_limit = nil
    @loop.history = [{ role: "user", content: "x" * 1000 }]

    @manager.evaluate_context_compaction!

    assert_equal 1, @loop.history.size
  end

  def test_no_compaction_when_history_within_ceiling
    @loop.context_limit = 32_768
    @loop.history = [{ role: "user", content: "small" }]

    @manager.evaluate_context_compaction!

    assert_equal 1, @loop.history.size
    assert_equal "small", @loop.history.first[:content]
  end

  def test_compaction_rebinds_history_on_loop_when_over_ceiling
    @loop.context_limit = 1_024
    @loop.max_output_tokens = 128
    @loop.history = Array.new(60) { |i| { role: "user", content: ("x" * 300) + i.to_s } }

    original_history_id = @loop.history.object_id
    @manager.evaluate_context_compaction!

    refute_equal original_history_id, @loop.history.object_id,
                 "history must be rebound on the loop (compaction returns a new array)"
    assert_operator @loop.history.size, :<, 60
  end

  def test_compaction_respects_config_disabling_strategy
    @loop.context_limit = 1_024
    @loop.max_output_tokens = 128
    @loop.config = { "context" => { "compaction_strategy" => "off" } }
    @loop.history = Array.new(60) { |i| { role: "user", content: ("x" * 300) + i.to_s } }

    @manager.evaluate_context_compaction!

    # "off" strategy duplicates messages but does not compact them away
    assert_equal 60, @loop.history.size
  end

  def test_compaction_succeeds_without_runtime_manager_on_loop
    bare_loop = Struct.new(:context_limit, :max_output_tokens, :history, :config).new(
      1_024, 128, Array.new(60) { |i| { role: "user", content: ("x" * 300) + i.to_s } }, nil
    )
    deps = Rubik::Orchestrator::ShellDeps.new(bare_loop)
    manager = Rubik::Orchestrator::BudgetManager.new(deps)

    manager.evaluate_context_compaction!

    assert_operator bare_loop.history.size, :<, 60
  end

  # ── track_token_usage! ─────────────────────────────────────────────

  def test_tracks_input_and_output_tokens
    res = Rubik::LLM::Response.new(text: "x", usage: { input_tokens: 100, output_tokens: 40 })

    @manager.track_token_usage!(res)

    assert_equal 100, @loop.total_tokens[:input]
    assert_equal 40, @loop.total_tokens[:output]
  end

  def test_accumulates_across_calls
    3.times do
      @manager.track_token_usage!(Rubik::LLM::Response.new(text: "x", usage: { input_tokens: 10, output_tokens: 5 }))
    end

    assert_equal 30, @loop.total_tokens[:input]
    assert_equal 15, @loop.total_tokens[:output]
  end

  def test_ignores_response_without_usage
    res = Rubik::LLM::Response.new(text: "no usage")

    @manager.track_token_usage!(res)

    assert_equal 0, @loop.total_tokens[:input]
    assert_equal 0, @loop.total_tokens[:output]
  end

  def test_handles_string_keyed_usage
    res = Rubik::LLM::Response.new(text: "x", usage: { "input_tokens" => 7, "output_tokens" => 3 })

    @manager.track_token_usage!(res)

    assert_equal 7, @loop.total_tokens[:input]
    assert_equal 3, @loop.total_tokens[:output]
  end

  def test_handles_object_without_usage_responder
    res = Object.new
    @manager.track_token_usage!(res)

    assert_equal 0, @loop.total_tokens[:input]
  end

  # ── warn_context_truncation! ───────────────────────────────────────

  def test_emits_truncation_warning_once_near_limit
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.context_limit = 10_000
    @loop.step_count = 5
    @loop.max_steps = 40

    @manager.warn_context_truncation!(9_500) # > 90% of 10_000

    assert_equal 1, events.size
    assert_equal :context_truncation_warning, events.first[:type]
    assert_equal 9_500, events.first[:input_tokens]
    assert_equal 10_000, events.first[:context_limit]
    assert_equal 5, events.first[:step]

    # Second call with the flag set does not emit again
    @manager.warn_context_truncation!(9_900)
    assert_equal 1, events.size
  end

  def test_no_truncation_warning_when_below_ninety_percent
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.context_limit = 10_000

    @manager.warn_context_truncation!(8_000)

    assert_empty events
  end

  def test_no_truncation_warning_when_context_limit_nil
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.context_limit = nil

    @manager.warn_context_truncation!(5_000)

    assert_empty events
  end

  def test_no_truncation_warning_when_zero_tokens
    events = []
    @loop.on_step = ->(info) { events << info }
    @loop.context_limit = 10_000

    @manager.warn_context_truncation!(0)

    assert_empty events
  end

  # ── estimate_tokens_from_history ───────────────────────────────────

  def test_estimates_tokens_from_history
    @loop.history = [
      { role: "user", content: "hello world" },
      { role: "assistant", content: "hi there" }
    ]

    estimate = @manager.estimate_tokens_from_history

    assert_kind_of Integer, estimate
    assert_operator estimate, :>=, 0
  end

  def test_estimate_empty_history_is_zero
    @loop.history = []
    assert_equal 0, @manager.estimate_tokens_from_history
  end
end
