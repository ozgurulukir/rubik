# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Pruner apply seam (context-pruner 2026-10-09): aşamalı plan turn
# sınırında, orchestrator.run pencereyi tohumlamadan ÖNCE uygulanır —
# execute_free_text yolu gerçek Shell ile; !goal yolu CommandContext fiili
# delegasyonuyla; replay sırasında ve pruner kapalıyken (coeffect yok)
# no-op; hasat boşsa turn normal ilerler.
class TestPrunerApplySeam < Minitest::Test
  # Tek atımlık sahte harness: take_applicable_plan! bir kez pencere+
  # makbuz döner (sonra nil), çağrıları kaydeder.
  class SeamHarness
    attr_reader :calls

    def initialize(new_window = nil)
      @new_window = new_window
      @receipt = { dropped: 1, summarized: 0, skipped_stale: 0, before_tokens: 100, after_tokens: 50 }
      @calls = 0
    end

    def take_applicable_plan!(_live_window)
      @calls += 1
      return nil if @new_window.nil?

      window = @new_window
      @new_window = nil
      [window, @receipt]
    end

    def prune(*) = "Prune queued (async) receipt"

    def status_text = "Context pruner:\n  window: 0 entries"

    def dmesg = nil
  end

  def capturing_provider(captured)
    provider = Object.new
    provider.define_singleton_method(:complete) do |msgs, _opts = {}|
      captured.replace(Array(msgs))
      Rubik::LLM::Response.new(text: "done", usage: { input_tokens: 10, output_tokens: 5 })
    end
    provider
  end

  def stub_router!(provider)
    router = Object.new
    router.define_singleton_method(:route) do |*_a, **_kw|
      { role: "default", model: "mock-1", provider: provider,
        spec: { "provider" => "mock", "name" => "test" },
        context_limit: 32_768, max_output_tokens: 4_096 }
    end
    @shell.instance_variable_set(:@router, router)
  end

  def seeded_window
    [
      { role: "user", content: "original question" },
      { role: "assistant", content: "SENTINEL-DROP superseded exploration" },
      { role: "user", content: "follow up" },
      { role: "assistant", content: "answer" }
    ]
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_pruner_seam")
    @temp_home = Dir.mktmpdir("rubik_pruner_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def provide_pruner!(harness)
    @shell.runtime_manager.provide(Rubik::Coeffects::PRUNER, harness)
  end

  def test_staged_plan_swaps_the_window_before_the_loop_seeds
    captured = []
    stub_router!(capturing_provider(captured))
    @shell.conversation_history = seeded_window
    pruned = seeded_window.reject { |r| r[:content].to_s.include?("SENTINEL-DROP") }
    provide_pruner!(SeamHarness.new(pruned))

    @shell.execute_free_text("fresh turn")

    refute @shell.conversation_history.any? { |r| r[:content].to_s.include?("SENTINEL-DROP") },
           "the pruned row left the live window for good"
    refute captured.any? { |m| (m[:content] || m["content"]).to_s.include?("SENTINEL-DROP") },
           "the Loop seeded from the PRUNED window (apply ran before orchestrator.run)"
    assert captured.any? { |m| (m[:content] || m["content"]).to_s.include?("fresh turn") },
           "the new turn still seeds (goal arrives wrapped in <user_task>)"
    assert_includes @output.string, "[Pruner] Applied staged plan", "the user sees the one-line apply receipt"
  end

  def test_no_harness_is_a_noop_and_the_turn_proceeds
    captured = []
    stub_router!(capturing_provider(captured))
    @shell.conversation_history = seeded_window

    @shell.execute_free_text("plain turn")

    assert captured.any? { |m| (m[:content] || m["content"]).to_s == "SENTINEL-DROP superseded exploration" },
           "knob off → no coeffect → window untouched"
  end

  def test_nil_take_is_a_noop_and_failures_never_break_the_turn
    captured = []
    stub_router!(capturing_provider(captured))
    @shell.conversation_history = seeded_window
    provide_pruner!(SeamHarness.new(nil)) # hasat yok / canlı doğrulama düştü

    @shell.execute_free_text("another turn")

    assert captured.any? { |m| (m[:content] || m["content"]).to_s == "SENTINEL-DROP superseded exploration" },
           "nil from take_applicable_plan! leaves the window exactly as it was"
  end

  def test_replay_skips_the_apply_entirely
    captured = []
    stub_router!(capturing_provider(captured))
    @shell.conversation_history = seeded_window
    harness = SeamHarness.new([])
    provide_pruner!(harness)
    @shell.instance_variable_set(:@replaying, true)

    @shell.execute_free_text("replayed turn")

    assert_equal 0, harness.calls, "session replay must not prune the window"
  ensure
    @shell.instance_variable_set(:@replaying, false)
  end

  def test_command_context_verb_delegates_to_the_shell
    calls = []
    shell = Object.new
    shell.define_singleton_method(:apply_staged_prune_plan!) { calls << :applied }
    ctx = Rubik::REPL::CommandContext.new(shell)
    ctx.apply_staged_prune_plan!
    assert_equal [:applied], calls, "the !goal path reaches the same seam through the closed verb"
  end
end
