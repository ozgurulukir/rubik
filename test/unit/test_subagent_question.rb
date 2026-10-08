# frozen_string_literal: true

require_relative "../test_helper"

# Pins for the subagent → maestro question channel: the ask_question tool's
# subagent plane (SUBAGENT_QUESTION_ASKER coeffect), the Questioner poll
# (waiting_input → inbox answer), the :question notice vocabulary, and the
# prompt disclosures on both planes.
class TestSubagentQuestion < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @child_context = @root_context.extend
    @bus = Rubik::EventBus.new
    @inst = new_instance
    @child_context.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, @inst)
  end

  def teardown
    @inst.cleanup
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def new_instance(event_bus: @bus)
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-q", parent_id: "agent-0", role: "Questioner", type_name: "research",
      prompt: "Work", context: @child_context, tool_registry: nil,
      max_steps: 10, root_dir: @ws_root, event_bus: event_bus
    )
    # This file drives the Questioner on the MAIN thread (no worker), so
    # take the seat the way start_async would: the legal pending -> running
    # flip through the guarded seam.
    inst.transition!(:running)
    inst
  end

  def subagent_tool
    Rubik::Tools::AskQuestionTool.new(shell: nil, runtime_context: @child_context)
  end

  def test_round_trip_tool_to_init0_and_back
    payloads = []
    @bus.subscribe(Rubik::Orchestrator::Subagent::Notices::QUESTION_EVENT) { |p| payloads << p }
    result = nil
    thread = Thread.new do
      result = subagent_tool.execute(
        "questions" => [{ "question" => "Which DB?", "options" => ["PostgreSQL", "SQLite"] }]
      )
    end
    wait_until { @inst.state == :waiting_input }
    wait_until { payloads.size == 1 }

    assert_equal "subagent-q", payloads.first[:id]
    assert_includes payloads.first[:reason], "Which DB?"
    assert_includes payloads.first[:reason], "PostgreSQL / SQLite"
    assert_includes @inst.to_h[:state_note].to_s, "clarifying question", "status carries the wait story (derived from state)"

    @inst.post_message("PostgreSQL")
    thread.join(5)
    refute_nil result, "tool must return after the answer"
    refute result.error?, result.to_s
    assert_includes result.to_s, "Maestro answered: PostgreSQL"
    assert_equal :running, @inst.state, "guarded restore after the answer"
  end

  def test_timeout_returns_nil_and_restores_running
    before_steps = @inst.current_step
    answer = @inst.ask_init0("Stuck?", options: ["A", "B"], timeout: 0.2)

    assert_nil answer
    assert_equal :running, @inst.state
    assert_equal before_steps, @inst.current_step, "waiting consumes no step budget"
  end

  def test_pre_question_steer_is_drained_to_history_not_consumed_as_answer
    @inst.post_message("old steer: use Redis")
    result = nil
    thread = Thread.new do
      result = subagent_tool.execute(
        "questions" => [{ "question" => "Which DB?", "options" => ["PostgreSQL", "SQLite"] }]
      )
    end
    wait_until { @inst.state == :waiting_input }

    steer = @inst.history.find { |m| m[:content].to_s.include?("old steer") }
    refute_nil steer, "the pre-question steer drains into history at ask time"
    @inst.post_message("PostgreSQL")
    thread.join(5)
    assert_includes result.to_s, "Maestro answered: PostgreSQL", "the answer slot is reserved for post-question replies"
  end

  def test_question_timeout_reads_config_and_override
    cfg = Object.new
    def cfg.fetch(_key, _default) = 7
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-t", parent_id: "agent-0", role: "T", type_name: "research",
      prompt: "P", context: @child_context, tool_registry: nil, max_steps: 5,
      root_dir: @ws_root, event_bus: @bus, config: cfg
    )

    assert_equal 7, inst.question_timeout, "config-supplied timeout wins"
    assert_equal 0.5, inst.question_timeout(0.5), "a positive override beats config"
    assert_equal 7, inst.question_timeout(0), "non-positive overrides fall back to config"
    assert_equal 300, @inst.question_timeout, "nil config falls to the default"
  end

  def test_without_event_bus_nobody_can_answer_so_no_block
    inst = new_instance(event_bus: nil)

    assert_equal :unavailable, inst.ask_init0("Anyone?", options: ["A", "B"])
    assert_equal :running, inst.state, "no bus, no wait"
  end

  def test_kill_wakes_the_poller
    returned = :never
    thread = Thread.new { returned = @inst.ask_init0("Stuck?", options: ["A", "B"], timeout: 30) }
    wait_until { @inst.state == :waiting_input }
    t0 = Time.now
    @inst.kill

    thread.join(3)
    assert_nil returned, "poller exits on kill instead of honoring the full timeout"
    assert Time.now - t0 < 0.8, "kill must break the poll within a couple of ticks"
  end

  def test_scoped_registry_rebinds_ask_question_to_child_context
    source = Rubik::Tools::Registry.new
    source.register(Rubik::Tools::AskQuestionTool.new(shell: nil, runtime_context: @root_context))
    type_def = Rubik::Orchestrator::Subagent::TypeRegistry.new.get("research")
    scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source, type_def: type_def, child_ctx: @child_context,
      buffer: nil, parent_buffer: nil
    )

    rebound = scoped.get("ask_question")
    refute_nil rebound, "research filter must keep ask_question"
    assert_same @child_context, rebound.instance_variable_get(:@runtime_context),
                "subagent plane binds the child ctx, never the root dialog tool"
    refute_same source.get("ask_question"), rebound, "a fresh tool instance is minted per spawn"
  end

  def test_tool_timeout_output_lets_subagent_continue
    @inst.define_singleton_method(:ask_init0) { |_q, **| nil }

    res = subagent_tool.execute("questions" => [{ "question" => "Q?", "options" => ["A", "B"] }])
    refute res.error?, "timeout is guidance, not failure"
    assert_includes res.to_s, "No answer from the maestro"
    assert_includes res.to_s, "best judgment"
  end

  def test_multi_question_batch_is_one_blocking_round_trip
    captured = nil
    fake_asker = Object.new
    fake_asker.define_singleton_method(:ask_init0) do |q, options: []|
      captured = [q, options]
      "Both B"
    end
    @child_context.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, fake_asker)

    res = subagent_tool.execute(
      "questions" => [
        { "question" => "First?", "options" => ["A", "B"] },
        { "question" => "Second?", "options" => ["B", "C"] }
      ]
    )

    combined, options = captured
    assert_includes combined, "1. First?", "questions are numbered into one ask"
    assert_includes combined, "2. Second?"
    assert_equal ["A", "B", "C"], options, "options are flattened and deduped"
    assert_includes res.to_s, "Maestro answered: Both B"
  end

  def test_root_plane_keeps_human_dialog_behavior
    tool = Rubik::Tools::AskQuestionTool.new(shell: nil, runtime_context: @root_context)

    res = tool.execute("questions" => [{ "question" => "Which?", "options" => ["A", "B"] }])
    assert_includes res.to_s, "automatically selected", "root ctx (no asker) keeps the dialog/fallback plane"
  end

  def test_question_notice_vocabulary
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::QUESTION_EVENT,
      { id: "subagent-3", role: "Explorer", state: :waiting_input,
        reason: "Depth-first or breadth-first? (options: DFS / BFS)", timeout: 300 }
    )

    assert_equal :question, notice[:kind]
    line = Rubik::Orchestrator::Subagent::Notices.user_line(notice)
    assert_includes line, "❓ [Question from subagent-3]"
    assert_includes line, "DFS / BFS"
    element = Rubik::Orchestrator::Subagent::Notices.model_element(notice)
    assert_includes element, 'reason="Depth-first or breadth-first? (options: DFS / BFS)"'
    guidance = Rubik::Orchestrator::Subagent::Notices.guidance_for(notice)
    assert_includes guidance, "send_message(recipient: 'subagent-3'"
    assert_includes guidance, "blocked waiting"
  end

  def test_wake_kinds_and_event_map_cover_question
    assert_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :question
    assert_includes Rubik::Orchestrator::Subagent::Notices::EVENTS.keys,
                    Rubik::Orchestrator::Subagent::Notices::QUESTION_EVENT
  end

  def test_archetype_tool_lists_and_prompts_disclose_the_channel
    assert_includes Rubik::Orchestrator::Subagent::TypeRegistry::READ_ONLY_TOOLS, "ask_question"
    assert_includes Rubik::Orchestrator::Subagent::TypeRegistry::CODER_TOOLS, "ask_question"

    prompt = @inst.send(:build_effective_system_prompt)
    assert_includes prompt, "ask_question tool", "base subagent prompt discloses the channel"
    registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    assert_includes registry.get("research").system_prompt, "ask the maestro with the ask_question tool"
    assert_includes registry.get("coder").system_prompt, "ask the maestro with the"
  end

  def test_supervisor_spawn_provides_asker_into_child_context
    gate = Queue.new
    fake_provider = Object.new
    fake_provider.define_singleton_method(:complete) do |_history, _opts|
      gate.pop
      {}
    end
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root, provider: fake_provider
    )
    inst = supervisor.spawn(role: "Asker", prompt: "Do the thing")
    wait_until { inst.state == :running }

    child = inst.context
    assert_equal inst, Rubik::Coeffects.get(child, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER),
                 "spawn wires the asker coeffect into the disposable child context"
    assert_nil Rubik::Coeffects.get(@root_context, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER),
               "root plane stays dialog-only"
  ensure
    gate << :release
    supervisor&.shutdown_all
  end

  def test_wait_for_does_not_block_on_question_pending_subagent
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root
    )
    inst = new_instance
    # A real question in flight: the asker thread blocks in the poll loop.
    asker = Thread.new { inst.ask_init0("Which way?", options: ["A", "B"], timeout: 30) }
    wait_until { inst.awaiting_human? }
    supervisor.instances[inst.id] = inst

    t0 = Time.now
    rows = supervisor.wait_for([inst.id], timeout: 3)

    assert Time.now - t0 < 2, "a question-blocked subagent must not burn the wait timeout"
    assert_equal "waiting_input", rows.first[:state]

    inst.post_message("A")
    asker.join(2)
  end

  def test_manage_subagents_guidance_for_waiting_input
    guidance = Rubik::Orchestrator::Subagent::Narration.guidance("waiting_input", id: "subagent-9", max_steps: 10)

    assert_includes guidance, "BLOCKED"
    assert_includes guidance, "send_message(recipient: 'subagent-9'"
  end

  def test_rule7_discloses_the_answering_duty
    xml = Rubik::Prompt::Doctrine.operational_rules_xml

    assert_includes xml, "BLOCKED until you reply"
    assert_includes xml, "ask_question"
  end

  private

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now >= deadline
  end
end
