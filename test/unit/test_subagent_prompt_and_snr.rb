# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentPromptAndSnr < Minitest::Test
  def setup
    @type_registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
  end

  def test_context_builder_build_subagents_xml_with_default_registry
    xml = Rubik::Prompt::ContextBuilder.build_subagents_xml(@type_registry)

    assert_includes xml, '<subagents count="3">'
    assert_includes xml, '<subagent name="research" tools="read_only" default_workspace="inherit">'
    assert_includes xml, '<subagent name="coder" tools="read_write_test" default_workspace="branch">'
    assert_includes xml, '<subagent name="self" tools="full_clone" default_workspace="inherit">'
    assert_includes xml, "<orchestration_guidance>"
    assert_includes xml, "MUST use 'coder' for code changes/bug fixes"
    assert_includes xml, "manage_subagents(action: 'wait', conversation_ids: [...], timeout: 30)"
    assert_includes xml, "Do NOT poll 'status' in a loop"
    # Pin the rendered budget hint so a future heredoc-quoting flip turns red.
    assert_includes xml, "manage_subagents(action: 'extend_budget', conversation_id: '[...]', steps: 20)"
    assert_includes xml, "Extend BEFORE absorbing the task yourself"
    # Plan 109: the reactive wake promise is now a mechanism, not just text.
    assert_includes xml, "automatically wake you with a notification-evaluation turn while you are idle"
    assert_includes xml, "</subagents>"
  end

  def test_context_builder_build_subagents_xml_empty_or_nil
    assert_equal "", Rubik::Prompt::ContextBuilder.build_subagents_xml(nil)
    assert_equal "", Rubik::Prompt::ContextBuilder.build_subagents_xml([])
  end

  def test_build_system_prompt_integrates_subagents_and_operational_rules
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      type_registry: @type_registry
    )

    # Structural integration pin: both sections land in the assembled
    # prompt. The rule/guidance SENTENCES are doctrine invariants — they
    # moved to test_prompt_doctrine (Phase 4); the golden fixtures pin
    # the absolute bytes.
    assert_includes prompt, '<subagents count="3">'
    assert_includes prompt, "<orchestration_guidance>"
    assert_includes prompt, "<operational_rules>"
    assert_includes prompt, "</system_context>"
  end

  def test_invoke_subagent_tool_output_recommends_wait_action
    mock_sup = Object.new

    def mock_sup.spawn_batch(specs)
      specs.map do |_spec|
        [:launched, Struct.new(:id, :role, :type_name, :state).new("subagent-1", "Bug Fixer", "coder", :running)]
      end
    end

    def mock_sup.spawn(**_kwargs)
      Struct.new(:id, :role, :type_name, :state).new("subagent-1", "Bug Fixer", "coder", :running)
    end

    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: mock_sup)
    output = tool.execute(role: "Bug Fixer", prompt: "Fix authentication bug", type_name: "coder")

    assert_includes output, "Launched 1 background subagent(s):"
    assert_includes output, "[subagent-1] 'Bug Fixer' (coder) - RUNNING"
    assert_includes output, "call manage_subagents(action: 'wait', conversation_ids: ['subagent-1'], timeout: 30)"
    refute_includes output, 'conversation_ids: ["subagent-1"]', "wait hints render single-quoted ids, never Array#inspect"
    refute_includes output, "action: 'status'"
  end

  def test_loop_drains_subagent_notices_into_history
    loop_inst = Rubik::Orchestrator::Loop.allocate
    loop_inst.instance_variable_set(:@history, [])
    loop_inst.enqueue_subagent_notice(completed_notice(id: "subagent-1", role: "Tester"))
    loop_inst.enqueue_subagent_notice(budget_notice(id: "subagent-2", role: "Worker", max_steps: 10))

    loop_inst.drain_subagent_notices_into_history!

    history = loop_inst.history
    assert_equal 1, history.size
    assert_equal "user", history.first[:role]
    content = history.first[:content]

    assert_includes content, "<subagent_notifications>"
    assert_includes content, '<notification kind="completed" id="subagent-1" role="Tester" state="completed"'
    assert_includes content, '<notification kind="budget_exhausted" id="subagent-2" role="Worker" state="waiting_budget" max_steps="10"'
    assert_includes content, "</subagent_notifications>"
    refute_includes content, "!subagents", "Model channel must carry tool guidance, never REPL syntax"

    # Second drain is a no-op
    loop_inst.drain_subagent_notices_into_history!
    assert_equal 1, history.size
  end

  def test_loop_drain_merges_into_existing_user_turn
    loop_inst = Rubik::Orchestrator::Loop.allocate
    loop_inst.instance_variable_set(:@history, [{ role: "user", content: "Fix the bug" }])
    loop_inst.enqueue_subagent_notice(completed_notice(id: "subagent-1", role: "Tester"))
    loop_inst.drain_subagent_notices_into_history!

    history = loop_inst.history
    # Merged into existing user turn — no consecutive user messages
    assert_equal 1, history.size
    assert_includes history.first[:content], "Fix the bug"
    assert_includes history.first[:content], "<subagent_notifications>"
  end

  def test_loop_drain_creates_new_turn_after_assistant
    loop_inst = Rubik::Orchestrator::Loop.allocate
    loop_inst.instance_variable_set(:@history, [{ role: "assistant", content: "working on it" }])
    loop_inst.enqueue_subagent_notice(completed_notice(id: "subagent-1", role: "Tester"))
    loop_inst.drain_subagent_notices_into_history!

    history = loop_inst.history
    # New user turn created after assistant turn
    assert_equal 2, history.size
    assert_equal "assistant", history[0][:role]
    assert_equal "user", history[1][:role]
    assert_includes history[1][:content], "<subagent_notifications>"
  end

  def test_loop_enqueue_notice_rejects_legacy_string_dialect
    loop_inst = Rubik::Orchestrator::Loop.allocate

    error = assert_raises(ArgumentError) { loop_inst.enqueue_subagent_notice("⚡ legacy string") }
    assert_includes error.message, "Hash with :kind"
  end

  def test_loop_run_resets_stale_subagent_notices
    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      Struct.new(:text, :tool_calls?, :tool_calls, :usage).new("done", false, [], nil)
    end

    loop_inst = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: Rubik::Tools::Registry.new,
      max_steps: 1
    )
    loop_inst.enqueue_subagent_notice(completed_notice(id: "stale-1", role: "Ghost"))

    loop_inst.run("fresh task", plan_only: true)

    assert_nil loop_inst.history.find { |m| m[:content].to_s.include?("<subagent_notifications>") },
               "A notice enqueued before run() must not drain into the fresh history"
  end

  def test_continue_loop_retains_pending_notices
    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      Struct.new(:text, :tool_calls?, :tool_calls, :usage).new("done", false, [], nil)
    end
    loop_inst = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: Rubik::Tools::Registry.new,
      max_steps: 1
    )
    loop_inst.run("first task", plan_only: true)
    loop_inst.enqueue_subagent_notice(completed_notice(id: "subagent-9", role: "Late Finisher"))

    loop_inst.continue_loop(5, plan_only: true)

    assert loop_inst.history.any? { |m| m[:content].to_s.include?("<subagent_notifications>") },
           "A notice enqueued before continue_loop must survive into the continuation (keep_for_continuation)"
  end

  def test_notices_budget_pause_splits_user_and_model_channels
    notice = budget_notice(id: "subagent-2", role: "Worker", max_steps: 10)
    notices = Rubik::Orchestrator::Subagent::Notices

    user = notices.user_line(notice)
    assert_includes user, "⚠️ [Subagent Paused] [subagent-2] 'Worker' reached step budget (10 steps)"
    assert_includes user, "!subagents extend subagent-2"

    model = notices.model_element(notice)
    assert_includes model, 'kind="budget_exhausted"'
    # Guidance text is an attribute value: single quotes are XML-escaped too.
    assert_includes model, "manage_subagents(action: &#39;extend_budget&#39;, conversation_id: &#39;subagent-2&#39;"
    refute_includes model, "!subagents", "REPL syntax must never reach the model channel"
    refute_includes model, "⚠️"
  end

  def test_notices_completed_channels_and_attribute_escaping
    notice = completed_notice(id: "subagent-1", role: "O'Brien & Co")
    notices = Rubik::Orchestrator::Subagent::Notices

    assert_equal "⚡ [Subagent Completed] [subagent-1] 'O'Brien & Co' - COMPLETED", notices.user_line(notice)

    model = notices.model_element(notice)
    assert_includes model, 'kind="completed"'
    assert_includes model, 'role="O&#39;Brien &amp; Co"'
    assert_includes model, "manage_subagents(action: &#39;wait&#39;, conversation_ids: [&#39;subagent-1&#39;]"
    refute_includes model, "⚡"
    refute_includes model, 'result="', "No result teaser: the wait protocol stays authoritative"
  end

  def test_notices_wait_hint_family_renders_single_quote_dialect
    notices = Rubik::Orchestrator::Subagent::Notices

    assert_equal "manage_subagents(action: 'wait', conversation_ids: ['subagent-1'], timeout: 30)",
                 notices.wait_hint("subagent-1")
    assert_equal "manage_subagents(action: 'wait', conversation_ids: ['subagent-1', 'subagent-2'], timeout: 30)",
                 notices.wait_hint(["subagent-1", "subagent-2"])
    assert_equal "manage_subagents(action: 'wait', conversation_ids: ['subagent-9'], timeout: 5)",
                 notices.wait_hint("subagent-9", timeout: 5)
    assert_equal "manage_subagents(action: 'wait', timeout: 30)", notices.wait_any_hint
    assert_equal "manage_subagents(action: 'wait', conversation_ids: [...], timeout: 30)", notices.wait_hint_template
  end

  def test_notices_hint_family_quote_style_is_uniform
    notices = Rubik::Orchestrator::Subagent::Notices
    snippets = [notices.wait_hint(["a", "b"]), notices.wait_hint("solo"),
                notices.wait_any_hint, notices.wait_hint_template,
                notices.extend_budget_hint("x"), notices.extend_budget_hint("[...]")]

    snippets.each do |snippet|
      refute_includes snippet, '"', "hint dialect is single-quoted; Array#inspect is banned"
      refute_includes snippet, "!subagents", "REPL syntax never reaches the model channel"
    end
  end

  def test_notices_budget_phrase_builders_render_the_shared_spellings
    notices = Rubik::Orchestrator::Subagent::Notices

    assert_equal "Subagent reached step budget (5 steps) and paused. " \
                 "Call manage_subagents(action: 'extend_budget', conversation_id: 'subagent-1', steps: 20) to resume.",
                 notices.budget_paused_line("subagent-1", 5)
    assert_equal "Subagent reached step budget (10 steps) and halted: task was NOT completed. " \
                 "Inspect transcript or spawn a new subagent.",
                 notices.budget_exhausted_line(10)
    assert_equal "Subagent reached step budget and halted: task was NOT completed. " \
                 "Inspect transcript or spawn a new subagent.",
                 notices.budget_exhausted_line
  end

  def test_notices_auto_apply_guidance_carries_no_repl_syntax
    notice = { kind: :auto_apply_failed, id: "subagent-3", role: "Coder", state: "running", reason: "boom" }
    guidance = Rubik::Orchestrator::Subagent::Notices.guidance_for(notice)

    assert_includes guidance, "apply_buffer"
    refute_includes guidance, "!apply", "REPL syntax must never reach the model channel"
  end

  def test_notices_user_line_reflects_failure_state
    notice = completed_notice(id: "subagent-9", role: "Crasher", state: :failed)
    user = Rubik::Orchestrator::Subagent::Notices.user_line(notice)

    assert_includes user, "❌ [Subagent Failed] [subagent-9] 'Crasher'"
    assert_includes user, "manage_subagents(action: 'status', conversation_id: 'subagent-9')"
    refute_includes user, "⚡ [Subagent Completed]"
  end

  def test_notices_normalize_drops_unknown_events
    assert_nil Rubik::Orchestrator::Subagent::Notices.normalize(:something_else, { id: "x" })
  end

  def test_lifecycle_routes_structured_notice_to_active_loop_and_buffers_user_line
    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |notice| received << notice }

    shell = notice_shell(mock_loop)
    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "subagent-1", role: "Tester", state: :completed })

    assert_equal 1, received.size
    assert_equal :completed, received.first[:kind]
    assert_equal "subagent-1", received.first[:id]
    assert_equal ["⚡ [Subagent Completed] [subagent-1] 'Tester' - COMPLETED"], shell.subagent_notices
    assert shell.output.string.empty?, "User line must stay buffered while a loop is active"
  end

  def test_lifecycle_prints_user_line_when_no_active_loop
    shell = notice_shell(nil)
    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "subagent-1", role: "Tester", state: :completed })

    assert_includes shell.output.string, "⚡ [Subagent Completed] [subagent-1] 'Tester' - COMPLETED"
    assert shell.subagent_notices.empty?
  end

  def test_lifecycle_gate_suppresses_notices_when_stopped_or_replaying
    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |notice| received << notice }
    shell = notice_shell(mock_loop)

    shell.replaying = true
    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "subagent-1", role: "Tester", state: :completed })
    shell.replaying = false
    shell.running = false
    shell.handle_subagent_event(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                                { id: "subagent-1", role: "Tester", state: :completed })

    assert received.empty?
    assert shell.subagent_notices.empty?
    assert shell.output.string.empty?
  end

  private

  def completed_notice(id:, role:, state: :completed)
    Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
      { id: id, role: role, state: state }
    )
  end

  def budget_notice(id:, role:, max_steps: 10, state: :waiting_budget)
    Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::BUDGET_EXHAUSTED_EVENT,
      { id: id, role: role, state: state, max_steps: max_steps }
    )
  end

  def notice_shell(active_loop)
    Class.new do
      include Rubik::REPL::Lifecycle

      attr_accessor :active_loop, :output, :running, :replaying, :subagent_notices_mutex, :subagent_notices

      def initialize(active_loop)
        @active_loop = active_loop
        @output = StringIO.new
        @running = true
        @replaying = false
        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
      end
    end.new(active_loop)
  end
end
