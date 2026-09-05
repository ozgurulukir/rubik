# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestUIPanel < Minitest::Test
  # Minimal fiber double exposing what Panel reads: name, state, instance,
  # inject, sub_context, last_error.
  class FiberDouble
    attr_reader :name, :state, :instance, :inject, :sub_context, :last_error

    def initialize(name:, state:, instance: nil, inject: [], sub_context: nil, last_error: nil)
      @name = name
      @state = state
      @instance = instance
      @inject = inject
      @sub_context = sub_context
      @last_error = last_error
    end

    def satisfiable?(_ctx = nil)
      @state == :active
    end

    def activate!(_ctx = nil)
      @state = :active
      true
    end

    def deactivate!
      @state = :pending
    end

    def dispose!
      @state = :disposed
    end
  end

  # Minimal loop-instance double exposing step_count/max_steps/total_tokens
  class LoopDouble
    attr_reader :step_count, :max_steps, :total_tokens

    def initialize(step_count: 0, max_steps: 40)
      @step_count = step_count
      @max_steps = max_steps
      @total_tokens = { input: 5, output: 3 }
    end
  end

  # Minimal context double exposing disposable_count
  class ContextDouble
    attr_reader :disposable_count

    def initialize(count = 2)
      @disposable_count = count
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_panel")
    @home_dir = Dir.mktmpdir("rubik_panel_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output)
    @theme = Rubik::UI::Theme.new(enabled: false)
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
  end

  def teardown
    @shell.stop
    @ctx.dispose unless @ctx.disposed?
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  # ── render ─────────────────────────────────────────────────────────

  def test_render_shows_empty_message_when_no_fibers
    @shell.runtime_manager.dispose!
    Rubik::UI::Panel.render(@shell, @theme)

    assert_includes @output.string, "Kayıtlı fiber/ajan yok."
  end

  def test_render_lists_fibers_with_state_glyphs
    @manager.register_fiber(FiberDouble.new(name: "worker", state: :active, instance: LoopDouble.new))
    @manager.register_fiber(FiberDouble.new(name: "idle", state: :pending))
    @manager.register_fiber(FiberDouble.new(name: "broken", state: :failed, last_error: RuntimeError.new("boom")))
    shell = Rubik::REPL::Shell.new(config: @config, output: @output)
    shell.instance_variable_set(:@runtime_manager, @manager)

    Rubik::UI::Panel.render(shell, @theme)

    out = @output.string
    assert_includes out, "=== Ajan / Fiber Panosu ==="
    assert_includes out, "🟢"
    assert_includes out, "⏳"
    assert_includes out, "🔴"
    assert_includes out, "worker"
    assert_includes out, "idle"
  end

  def test_render_sort_order_puts_active_first
    manager = Rubik::Runtime::Manager.new
    manager.register_fiber(FiberDouble.new(name: "z_active", state: :active, instance: LoopDouble.new))
    manager.register_fiber(FiberDouble.new(name: "a_pending", state: :pending))
    shell = Rubik::REPL::Shell.new(config: @config, output: @output)
    shell.instance_variable_set(:@runtime_manager, manager)

    Rubik::UI::Panel.render(shell, @theme)

    active_idx = @output.string.index("z_active")
    pending_idx = @output.string.index("a_pending")
    assert_operator active_idx, :<, pending_idx, "active fibers sort before pending"
  end

  # ── detail_line / current_activity ─────────────────────────────────

  def test_detail_line_for_active_loop_shows_step_count
    fiber = FiberDouble.new(name: "worker", state: :active, instance: LoopDouble.new(step_count: 3, max_steps: 10))

    line = Rubik::UI::Panel.detail_line(fiber, @theme)

    assert_includes line, "adım 3/10"
    assert_includes line, "worker"
  end

  def test_detail_line_for_failed_fiber_shows_error
    fiber = FiberDouble.new(name: "broken", state: :failed, last_error: RuntimeError.new("syntax error"))

    line = Rubik::UI::Panel.detail_line(fiber, @theme)

    assert_includes line, "hata: syntax error"
  end

  def test_detail_line_for_pending_fiber_shows_coeffects
    fiber = FiberDouble.new(name: "waiting", state: :pending, inject: ["llm_client", "buffer_manager"])

    line = Rubik::UI::Panel.detail_line(fiber, @theme)

    assert_includes line, "coeffects: llm_client, buffer_manager"
  end

  def test_detail_line_shows_omega_depth_for_active_loop
    loop_inst = LoopDouble.new(step_count: 0, max_steps: 5)
    fiber = FiberDouble.new(
      name: "worker", state: :active,
      instance: loop_inst,
      sub_context: ContextDouble.new(3)
    )

    line = Rubik::UI::Panel.detail_line(fiber, @theme)

    assert_includes line, "Ω3"
  end

  def test_current_activity_falls_back_to_dash_for_empty_deps
    fiber = FiberDouble.new(name: "quiet", state: :unloaded, inject: [])

    activity = Rubik::UI::Panel.current_activity(fiber)

    assert_equal "-", activity
  end

  # ── show_fiber_detail ──────────────────────────────────────────────

  def test_show_fiber_detail_prints_state_history_and_omega
    fiber = FiberDouble.new(
      name: "worker", state: :active,
      instance: LoopDouble.new(step_count: 2, max_steps: 10),
      inject: ["llm_client"],
      sub_context: ContextDouble.new(1)
    )

    Rubik::UI::Panel.show_fiber_detail(@shell, fiber, @theme)

    out = @output.string
    assert_includes out, "── worker ──"
    assert_includes out, "Durum"
    assert_includes out, "Coeffects"
    assert_includes out, "Ω derinliği"
    assert_includes out, "Adım"
    assert_includes out, "Token"
  end

  def test_show_fiber_detail_includes_error_when_present
    fiber = FiberDouble.new(name: "broken", state: :failed, last_error: RuntimeError.new("kapandı"))

    Rubik::UI::Panel.show_fiber_detail(@shell, fiber, @theme)

    assert_includes @output.string, "kapandı"
  end

  # ── interactive? / STATE_ORDER ─────────────────────────────────────

  def test_interactive_returns_false_for_stringio
    refute Rubik::UI::Panel.interactive?(@shell)
  end

  def test_state_order_constant
    assert_equal 0, Rubik::UI::Panel::STATE_ORDER[:active]
    assert_equal 1, Rubik::UI::Panel::STATE_ORDER[:pending]
    assert_equal 4, Rubik::UI::Panel::STATE_ORDER[:unloaded]
  end
end
