# frozen_string_literal: true

require_relative "../test_helper"

# Pruner::Service.bind (vakanüvis service emsali): knob kapalıysa (explicit
# opt-out) nil, SHELL/SUPERVISOR coeffect'leri yoksa dürüst nil + warn;
# varsayılan (ON, 2026-10-10) child ctx + worker + aboneliklerle kurulur,
# PRUNER coeffect'i köke sağlanır, dispose cascade'i worker'ı kapatır.
class TestPrunerService < Minitest::Test
  def setup
    @old_force = ENV.fetch("RUBIK_PRUNER_FORCE", nil)
    @old_test = ENV.fetch("RUBIK_TEST", nil)
    ENV["RUBIK_TEST"] = "1"
    ENV["RUBIK_PRUNER_FORCE"] = "1"
  end

  def teardown
    ENV["RUBIK_PRUNER_FORCE"] = @old_force
    ENV["RUBIK_TEST"] = @old_test
  end

  class SpyBus
    attr_reader :subscriptions

    def initialize
      @subscriptions = []
    end

    def subscribe(name, **_kwargs)
      @subscriptions << name
    end
  end

  ShellStub = Struct.new(:conversation_history)

  def enabled_cfg
    { "subagents" => { "pruner" => { "enabled" => true } } }
  end

  def wired_ctx(shell: ShellStub.new([]))
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::SHELL, shell)
    ctx.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, Object.new)
    ctx
  end

  def test_bind_is_nil_when_the_knob_is_off
    refute Rubik::REPL::Pruner::Service.bind(
      wired_ctx, config: { "subagents" => { "pruner" => { "enabled" => false } } }, event_bus: SpyBus.new
    ), "explicit opt-out → no harness, no coeffect (kill-switch preserved)"
  end

  def test_bind_boots_by_default_without_explicit_config
    ctx = wired_ctx
    bus = SpyBus.new
    harness = Rubik::REPL::Pruner::Service.bind(ctx, config: nil, event_bus: bus)
    assert harness.is_a?(Rubik::REPL::Pruner::Harness), "DEFAULT ON (2026-10-10): no config → the harness boots"
    assert_equal harness, ctx.get(Rubik::Coeffects::PRUNER)
    ctx.dispose
    assert_predicate harness, :stopped?
  end

  def test_bind_is_nil_under_test_armor_without_force
    ENV["RUBIK_PRUNER_FORCE"] = nil
    refute Rubik::REPL::Pruner::Service.bind(wired_ctx, config: enabled_cfg, event_bus: SpyBus.new),
           "RUBIK_TEST=1 armor keeps the suite pruner-free"
  end

  def test_bind_without_shell_or_supervisor_returns_nil
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, Object.new)
    assert_nil Rubik::REPL::Pruner::Service.bind(ctx, config: enabled_cfg, event_bus: SpyBus.new),
               "no SHELL coeffect → honest nil (boot-order gap)"

    ctx2 = Rubik::Runtime::Context.new
    ctx2.provide(Rubik::Coeffects::SHELL, ShellStub.new([]))
    assert_nil Rubik::REPL::Pruner::Service.bind(ctx2, config: enabled_cfg, event_bus: SpyBus.new),
               "no SUBAGENT_SUPERVISOR coeffect → honest nil (no spawn path)"
  end

  def test_bind_provides_the_coeffect_subscribes_and_disposes_cleanly
    ctx = wired_ctx
    bus = SpyBus.new
    harness = Rubik::REPL::Pruner::Service.bind(ctx, config: enabled_cfg, event_bus: bus)
    assert harness.is_a?(Rubik::REPL::Pruner::Harness)
    assert_equal harness, ctx.get(Rubik::Coeffects::PRUNER), "the tool/!prune plane resolves this coeffect"
    assert_includes bus.subscriptions, :turn_finished, "auto gate subscribes to turn boundaries"
    assert_includes bus.subscriptions, :subagent_completed, "harvest subscribes to completions"
    ctx.dispose
    assert_predicate harness, :stopped?, "ctx dispose cascade must shut the worker down"
  end
end
