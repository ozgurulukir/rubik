# frozen_string_literal: true

require_relative "../test_helper"

class TestShellDeps < Minitest::Test
  # Full-featured double carrying the whole declared read surface.
  class FullLoop
    attr_accessor :history, :activity, :config, :shell, :buffer_manager, :lsp_manager,
                  :tool_registry, :provider, :budget_manager, :on_step, :logger,
                  :step_count, :max_steps, :context_limit, :max_output_tokens,
                  :total_tokens, :invalid_tool_count, :last_turn_streamed,
                  :context_warning_emitted

    def safe_config(key, default)
      @config.respond_to?(:fetch) ? @config.fetch(key, default) : default
    end

    def emergency_compact_and_notify!(reason)
      @compacted_reason = reason
    end

    attr_reader :compacted_reason
  end

  # Minimal double: only a subset of the surface exists — capability
  # queries must reflect that instead of advertising the full surface.
  class MinimalLoop
    attr_accessor :history, :step_count
  end

  def setup
    @loop = FullLoop.new
    @loop.history = []
    @loop.total_tokens = { input: 0, output: 0 }
    @loop.invalid_tool_count = 0
    @loop.last_turn_streamed = false
    @loop.context_warning_emitted = false
    @deps = Rubik::Orchestrator::ShellDeps.new(@loop)
  end

  # ── Read surface forwarding ─────────────────────────────────────────

  def test_reads_are_forwarded_to_the_underlying_loop
    @loop.step_count = 7
    @loop.max_steps = 40

    assert_equal 7, @deps.step_count
    assert_equal 40, @deps.max_steps
    assert_equal @loop.history, @deps.history
    assert_equal @loop.total_tokens, @deps.total_tokens
  end

  def test_in_place_mutations_of_forwarded_references_reach_the_loop
    @deps.history << { role: "user", content: "hi" }
    @deps.total_tokens[:input] += 12

    assert_equal [{ role: "user", content: "hi" }], @loop.history
    assert_equal 12, @loop.total_tokens[:input]
  end

  def test_safe_config_is_forwarded_when_the_loop_defines_it
    @loop.config = { "llm.stream" => false }

    assert_equal false, @deps.safe_config("llm.stream", true)
    assert_equal 42, @deps.safe_config("missing.key", 42)
  end

  # ── Capability query forwarding ─────────────────────────────────────

  def test_respond_to_advertises_only_what_the_loop_actually_defines
    minimal = Rubik::Orchestrator::ShellDeps.new(MinimalLoop.new)

    assert_respond_to @deps, :safe_config
    assert_respond_to minimal, :history
    refute_respond_to minimal, :safe_config, "a loop without safe_config must not advertise it through the façade"
    refute_respond_to minimal, :max_steps
  end

  # ── Command surface ─────────────────────────────────────────────────

  def test_replace_history_rebinds_the_history_reference
    compacted = [{ role: "user", content: "compacted" }]
    @deps.replace_history!(compacted)

    assert_equal compacted, @loop.history
  end

  def test_invalid_tool_commands_reset_and_increment_the_counter
    @deps.record_invalid_tool!

    assert_equal 1, @loop.invalid_tool_count
    @deps.reset_invalid_tools!

    assert_equal 0, @loop.invalid_tool_count
  end

  def test_streamed_and_warning_flags_are_set_through_commands
    @deps.mark_last_turn_streamed!(true)
    @deps.flag_context_warning!

    assert_equal true, @loop.last_turn_streamed
    assert_equal true, @loop.context_warning_emitted
  end

  def test_emergency_compact_is_forwarded_with_its_reason
    @deps.emergency_compact_and_notify!("context overflow")

    assert_equal "context overflow", @loop.compacted_reason
  end

  # ── Contract pass-through and fail-fast ─────────────────────────────

  def test_loop_instance_exposes_the_underlying_loop_for_the_result_contract
    assert_same @loop, @deps.loop_instance
  end

  def test_symbols_outside_the_surface_fail_fast
    assert_raises(NoMethodError) { @deps.run("task") }
    assert_raises(NoMethodError) { @deps.some_undefined_state }
  end
end
