# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Issue #340: repl(vakanuvis): inject deterministic topics orientation at
# session start and after compaction.
class TestVakanuvisOrientation < Minitest::Test
  SLUG = "orientation-session-340"

  def setup
    @root = Dir.mktmpdir("rubik_vakanuvis_orientation")
    @home = Dir.mktmpdir("rubik_vakanuvis_home")
    @force_before = ENV.fetch("RUBIK_VAKANUIS_FORCE", nil)
    ENV["RUBIK_VAKANUIS_FORCE"] = "1"
  end

  def teardown
    ENV["RUBIK_VAKANUIS_FORCE"] = @force_before
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@home) if @home && Dir.exist?(@home)
  end

  def build_config
    Rubik::Config.new(root_dir: @root, home_dir: @home)
  end

  def build_store
    Rubik::Storage::Store.new(root: @root, project: "Orientation Spec")
  end

  def silent_bus
    bus = Object.new
    bus.define_singleton_method(:subscribe) { |*_a, **_kw, &blk| blk }
    bus
  end

  def bind_vakanuvis(ctx_or_mgr, store_obj: build_store, config: build_config)
    ctx = ctx_or_mgr.respond_to?(:context) ? ctx_or_mgr.context : ctx_or_mgr
    ctx.provide(Rubik::Coeffects::STORAGE_STORE, store_obj)
    Rubik::Storage::Vakanuvis::Service.bind(ctx_or_mgr, config: config, event_bus: silent_bus)
  end

  def seed_topics!(harness, count = 3)
    count.times do |i|
      idx = format("%02d", i + 1)
      harness.record(
        topic: "topic #{idx}",
        body: "First line for topic #{idx}\nSecond detail line that should not appear in excerpt"
      )
    end
  end

  def capturing_provider(captured_requests)
    provider = Object.new
    provider.define_singleton_method(:complete) do |msgs, _opts = {}|
      captured_requests << msgs.map(&:dup)
      Rubik::LLM::Response.new(text: "acknowledged", usage: { input_tokens: 12, output_tokens: 4 })
    end
    provider
  end

  def stub_router!(shell, provider)
    router = Object.new
    router.define_singleton_method(:route) do |*_a, **_kw|
      { role: "default", model: "mock-1", provider: provider,
        spec: { "provider" => "mock", "name" => "test" },
        context_limit: 32_768, max_output_tokens: 4_096 }
    end
    shell.instance_variable_set(:@router, router)
  end

  # ---- 1. Config defaults ---------------------------------------------------

  def test_config_defaults_include_orientation_switches
    cfg = build_config
    assert_equal true, cfg.fetch("subagents.vakanuvis.orientation")
    assert_equal 10, cfg.fetch("subagents.vakanuvis.orientation_max_topics")
  end

  # ---- 2. Deterministic excerpt & cap ---------------------------------------

  def test_format_excerpt_is_deterministic_capped_and_includes_uris_and_depth_hint
    cfg = build_config
    cfg.set("subagents.vakanuvis.orientation_max_topics", 2, persist: false)
    ctx = Rubik::Runtime::Context.new
    harness = bind_vakanuvis(ctx, config: cfg)
    seed_topics!(harness, 4)

    first = Rubik::Storage::Vakanuvis::Orientation.format_excerpt(harness, limit: 2)
    second = Rubik::Storage::Vakanuvis::Orientation.format_excerpt(harness, limit: 2)
    assert_equal first, second, "same store state must yield byte-identical orientation text"
    assert_includes first, "Recorded topics (2 of 4):"
    assert_includes first, "- mem.topic-01 — topic 01 — First line for topic 01 — rubik://storage/"
    assert_includes first, "- mem.topic-02 — topic 02 — First line for topic 02 — rubik://storage/"
    refute_includes first, "mem.topic-03", "topics beyond orientation_max_topics must be omitted"
    refute_includes first, "Second detail line", "only first body line belongs in the orientation index"
    assert_includes first, "Ask `vakanuvis(action: 'recall', query: '<2-3 terms>')` for depth."
  ensure
    ctx&.dispose
  end

  # ---- 3. Session start injection (once per session, before first model call)

  def test_fresh_session_with_cards_injects_one_orientation_message_before_first_model_call
    cfg = build_config
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @root)
    harness = Rubik::Coeffects.get(shell.runtime_manager.context, Rubik::Coeffects::VAKANUIS)
    refute_nil harness, "vakanuvis must bind when RUBIK_VAKANUIS_FORCE=1"
    seed_topics!(harness, 2)

    captured_requests = []
    stub_router!(shell, capturing_provider(captured_requests))

    shell.execute_free_text("first question")
    shell.execute_free_text("second question")

    assert_equal 2, captured_requests.size
    first_call_msgs = captured_requests[0]
    first_orientation_rows = first_call_msgs.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, first_orientation_rows.size, "first model call must include exactly one orientation message"
    assert_equal "user", first_orientation_rows.first[:role]

    # Must appear right after system prompt and before <user_task>
    sys_idx = first_call_msgs.index { |m| m[:role] == "system" }
    orient_idx = first_call_msgs.index { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    task_idx = first_call_msgs.index { |m| m[:content].to_s.include?("first question") }
    assert_operator orient_idx, :>, sys_idx
    assert_operator orient_idx, :<, task_idx

    # Second turn in the same session must NOT inject a second copy
    second_call_msgs = captured_requests[1]
    second_orientation_rows = second_call_msgs.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, second_orientation_rows.size, "subsequent turns must not duplicate the orientation message"
  ensure
    shell&.stop
  end

  # ---- 4. Empty store, disabled chronicler, and orientation=false -----------

  def test_no_injection_when_store_has_zero_active_cards
    cfg = build_config
    ctx = Rubik::Runtime::Context.new
    harness = bind_vakanuvis(ctx, config: cfg)
    # Record and immediately forget so 0 active cards remain
    harness.record(topic: "ephemeral", body: "gone soon")
    harness.forget(ref: "mem.ephemeral")

    history = [{ role: "system", content: "sys" }]
    res = Rubik::Storage::Vakanuvis::Orientation.inject_session_start!(history, ctx, config: cfg)
    assert_nil res, "N == 0 active cards must skip orientation injection"
    assert_equal 1, history.size
  ensure
    ctx&.dispose
  end

  def test_no_injection_when_orientation_knob_is_false_or_vakanuvis_disabled
    cfg = build_config
    cfg.set("subagents.vakanuvis.orientation", false, persist: false)
    ctx = Rubik::Runtime::Context.new
    harness = bind_vakanuvis(ctx, config: cfg)
    seed_topics!(harness, 2)

    history = [{ role: "system", content: "sys" }]
    assert_nil Rubik::Storage::Vakanuvis::Orientation.inject_session_start!(history, ctx, config: cfg)
    assert_nil Rubik::Storage::Vakanuvis::Orientation.inject_after_compaction!(history, ctx, config: cfg)
    assert_equal 1, history.size

    # Unsatisfied coeffect (chronicler unbound)
    empty_ctx = Rubik::Runtime::Context.new
    assert_nil Rubik::Storage::Vakanuvis::Orientation.inject_session_start!(history, empty_ctx, config: build_config)
  ensure
    ctx&.dispose
    empty_ctx&.dispose
  end

  # ---- 5. Compaction entry points & deduplication ---------------------------

  def test_compaction_entry_points_inject_fresh_orientation_and_deduplicate_stale_ones
    cfg = build_config
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @root)
    harness = Rubik::Coeffects.get(shell.runtime_manager.context, Rubik::Coeffects::VAKANUIS)
    seed_topics!(harness, 1)

    # A. Session start injects 1st orientation
    Rubik::Storage::Vakanuvis::Orientation.inject_session_start!(
      shell.conversation_history, shell.runtime_manager, config: cfg
    )
    shell.conversation_history << { role: "user", content: "turn 1" }
    shell.conversation_history << { role: "assistant", content: "reply 1" }
    assert_equal(1, shell.conversation_history.count { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) })

    # Record a new topic before compaction
    harness.record(topic: "post compact topic", body: "freshly learned fact")

    # B. Manual `!context compact`
    shell.commands["context"][:handler].call(["compact"], shell.command_context)
    orient_msgs = shell.conversation_history.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, orient_msgs.size, "!context compact must leave exactly one fresh orientation message"
    assert_includes orient_msgs.first[:content], "mem.post-compact-topic",
                    "post-compaction orientation must reflect newly recorded topics"

    # C. BudgetManager#evaluate_context_compaction!
    loop_inst = shell.orchestrator_loop(
      provider: capturing_provider([]), model: "mock-1",
      max_steps: 5, context_limit: 200, max_output_tokens: 50
    )
    loop_inst.history = [
      { role: "system", content: "sys" },
      orient_msgs.first.dup,
      { role: "user", content: "x" * 1000 },
      { role: "assistant", content: "y" * 1000 },
      { role: "user", content: "latest task" }
    ]
    bm = Rubik::Orchestrator::BudgetManager.new(loop_inst)
    bm.evaluate_context_compaction!
    bm_orient = loop_inst.history.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, bm_orient.size, "BudgetManager compaction must inject exactly one orientation message without duplicates"

    # D. Emergency compaction on UserChannel (`Loop#emergency_compact_and_notify!`)
    loop_inst.emergency_compact_and_notify!("413 payload too large")
    em_orient = loop_inst.history.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, em_orient.size, "Emergency compaction on UserChannel must inject exactly one fresh orientation message"

    # E. Staged Pruner apply (`TurnRecorder#apply_staged_prune_plan!`)
    pruner_stub = Object.new
    pruner_stub.define_singleton_method(:take_applicable_plan!) do |_win|
      [[{ role: "user", content: "surviving question" }, { role: "assistant", content: "surviving answer" }],
       { dropped: 2, summarized: 0, skipped_stale: 0, before_tokens: 500, after_tokens: 100 }]
    end
    shell.runtime_manager.provide(Rubik::Coeffects::PRUNER, pruner_stub)
    shell.apply_staged_prune_plan!
    pruner_orient = shell.conversation_history.select { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) }
    assert_equal 1, pruner_orient.size, "Staged pruner apply must inject one orientation message into the pruned window"
  ensure
    shell&.stop
  end

  # ---- 6. Stale orientation messages are droppable by Compactor -------------

  def test_orientation_message_is_not_goal_pinned_and_is_droppable_by_compactor
    cfg = build_config
    ctx = Rubik::Runtime::Context.new
    harness = bind_vakanuvis(ctx, config: cfg)
    seed_topics!(harness, 2)

    msg = Rubik::Storage::Vakanuvis::Orientation.resolve_hook(ctx, config: cfg).build_message
    refute_nil msg
    refute Rubik::Prompt::ContextCompactor.unit_pins_goal?([msg]),
           "orientation message must never be pinned as a goal unit by ContextCompactor"
  ensure
    ctx&.dispose
  end

  # ---- 7. Subagent isolation & system prompt byte-identity ------------------

  def test_subagent_compaction_never_receives_orientation_and_system_prompt_is_byte_identical
    cfg = build_config
    ctx = Rubik::Runtime::Context.new
    harness = bind_vakanuvis(ctx, config: cfg)
    seed_topics!(harness, 3)

    # Subagent::ContextCompaction + SubagentChannel must never inject vakanuvis orientation
    sub_history = [
      { role: "system", content: "subagent sys" },
      { role: "user", content: "<user_task>subagent job</user_task>" },
      { role: "assistant", content: "step 1 " * 400 },
      { role: "user", content: "step 2 " * 400 },
      { role: "assistant", content: "step 3" }
    ]
    sub_runner = Object.new
    sub_runner.extend(Rubik::Orchestrator::Subagent::ContextCompaction)
    sub_runner.instance_variable_set(:@history, sub_history)
    sub_runner.instance_variable_set(:@context_limit, 200)
    sub_runner.instance_variable_set(:@max_output_tokens, 50)
    sub_runner.instance_variable_set(:@config, cfg)
    sub_runner.define_singleton_method(:history) { @history }
    sub_runner.define_singleton_method(:context_limit) { @context_limit }
    sub_runner.define_singleton_method(:max_output_tokens) { @max_output_tokens }
    sub_runner.define_singleton_method(:config) { @config }
    sub_runner.define_singleton_method(:turn_executor) do
      @turn_executor ||= Rubik::Orchestrator::TurnExecutor.new(
        channel: Rubik::Orchestrator::TurnExecutor::SubagentChannel.new(self)
      )
    end
    sub_runner.evaluate_subagent_context_compaction!
    sub_runner.emergency_compact_and_notify!("413 subagent overflow")
    refute sub_history.any? { |m| Rubik::Storage::Vakanuvis::Orientation.orientation_message?(m) },
           "subagents do not see vakanuvis — subagent compaction must never inject orientation"

    # System prompt bytes must remain 100% identical with orientation ON vs OFF
    services_on = Rubik::Prompt::Services.new(config: cfg, root_dir: @root)
    prompt_on = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services_on)

    cfg.set("subagents.vakanuvis.orientation", false, persist: false)
    services_off = Rubik::Prompt::Services.new(config: cfg, root_dir: @root)
    prompt_off = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services_off)

    assert_equal prompt_off.bytes, prompt_on.bytes,
                 "system prompt must be byte-for-byte identical with and without orientation"
  ensure
    ctx&.dispose
  end

  # ---- 8. Revertible hook & zero-leak reload loop (AGENTS.md §1A & §6) ------

  def test_runtime_disable_and_reload_loop_leave_zero_orphan_hooks
    cfg = build_config
    store_obj = build_store
    root_ctx = Rubik::Runtime::Context.new
    root_ctx.provide(Rubik::Coeffects::STORAGE_STORE, store_obj)

    baseline_cleanups = root_ctx.disposable_count
    baseline_listeners = cfg.instance_variable_get(:@listeners).size

    # 100 bind/dispose cycles must return cleanups and config listeners to baseline
    bus = silent_bus
    100.times do
      sub = root_ctx.extend
      harness = Rubik::Storage::Vakanuvis::Service.bind(sub, config: cfg, event_bus: bus)
      seed_topics!(harness, 1) if store_obj.list(type: "memory").empty?
      refute_nil Rubik::Coeffects.get(sub, Rubik::Storage::Vakanuvis::Orientation::HOOK_KEY)
      sub.dispose
      assert_nil Rubik::Coeffects.get(sub, Rubik::Storage::Vakanuvis::Orientation::HOOK_KEY)
      assert_nil Rubik::Coeffects.get(sub, Rubik::Coeffects::VAKANUIS)
    end

    assert_equal baseline_cleanups, root_ctx.disposable_count,
                 "100 reload cycles must leave zero orphan inverses in root_ctx"
    assert_equal baseline_listeners, cfg.instance_variable_get(:@listeners).size,
                 "100 reload cycles must leave zero orphan config listeners"

    # Runtime disable via config observer removes the hook from ctx immediately
    sub = root_ctx.extend
    Rubik::Storage::Vakanuvis::Service.bind(sub, config: cfg, event_bus: bus)
    refute_nil sub.get(Rubik::Storage::Vakanuvis::Orientation::HOOK_KEY)

    cfg.set("subagents.vakanuvis.enabled", false, persist: false)
    assert_nil sub.get(Rubik::Storage::Vakanuvis::Orientation::HOOK_KEY),
               "disabling subagents.vakanuvis.enabled at runtime must remove the orientation hook from ctx"

    cfg.set("subagents.vakanuvis.enabled", true, persist: false)
    refute_nil sub.get(Rubik::Storage::Vakanuvis::Orientation::HOOK_KEY),
               "re-enabling subagents.vakanuvis.enabled at runtime must restore the orientation hook"
    sub.dispose
  ensure
    root_ctx&.dispose
  end
end
