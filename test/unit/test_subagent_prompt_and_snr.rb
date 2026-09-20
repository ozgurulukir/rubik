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

    assert_includes prompt, '<subagents count="3">'
    assert_includes prompt, "7. Subagent Delegation & Parallelism: For complex, parallel, or deep explorations"
    assert_includes prompt, "8. Runtime Introspection, Self-Healing & Human Feedback"
    assert_includes prompt, "MUST use 'coder' for code modifications"
    assert_includes prompt, "repair failed services via `repair_runtime_service`"
    assert_includes prompt, "use `ask_question` with structured multiple-choice options"
  end

  def test_invoke_subagent_tool_output_recommends_wait_action
    mock_sup = Object.new

    def mock_sup.spawn(**_kwargs)
      Struct.new(:id, :role, :type_name, :state).new("subagent-1", "Bug Fixer", "coder", :running)
    end

    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: mock_sup)
    output = tool.execute(role: "Bug Fixer", prompt: "Fix authentication bug", type_name: "coder")

    assert_includes output, "Launched 1 background subagent(s):"
    assert_includes output, "[subagent-1] 'Bug Fixer' (coder) - RUNNING"
    assert_includes output, "call manage_subagents(action: 'wait', conversation_ids: [\"subagent-1\"], timeout: 30)"
    refute_includes output, "action: 'status'"
  end

  def test_loop_drains_subagent_notices_into_history
    loop_inst = Rubik::Orchestrator::Loop.allocate
    loop_inst.instance_variable_set(:@history, [])
    loop_inst.instance_variable_set(:@subagent_notices, Queue.new)

    loop_inst.enqueue_subagent_notice("⚡ [Subagent Completed] [subagent-1] 'Tester' - COMPLETED")
    loop_inst.enqueue_subagent_notice("⚠️ [Subagent Paused] [subagent-2] 'Worker' reached step budget")

    loop_inst.drain_subagent_notices_into_history!

    history = loop_inst.history
    assert_equal 1, history.size
    assert_equal "user", history.first[:role]
    content = history.first[:content]

    assert_includes content, "<subagent_notifications>"
    assert_includes content, "<notification>⚡ [Subagent Completed] [subagent-1] &#39;Tester&#39; - COMPLETED</notification>"
    assert_includes content, "<notification>⚠️ [Subagent Paused] [subagent-2] &#39;Worker&#39; reached step budget</notification>"
    assert_includes content, "</subagent_notifications>"

    # Second drain is a no-op
    loop_inst.drain_subagent_notices_into_history!
    assert_equal 1, history.size
  end

  def test_loop_drain_merges_into_existing_user_turn
    loop_inst = Rubik::Orchestrator::Loop.allocate
    loop_inst.instance_variable_set(:@history, [{ role: "user", content: "Fix the bug" }])
    loop_inst.instance_variable_set(:@subagent_notices, Queue.new)

    loop_inst.enqueue_subagent_notice("⚡ Done")
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
    loop_inst.instance_variable_set(:@subagent_notices, Queue.new)

    loop_inst.enqueue_subagent_notice("⚡ Done")
    loop_inst.drain_subagent_notices_into_history!

    history = loop_inst.history
    # New user turn created after assistant turn
    assert_equal 2, history.size
    assert_equal "assistant", history[0][:role]
    assert_equal "user", history[1][:role]
    assert_includes history[1][:content], "<subagent_notifications>"
  end

  def test_lifecycle_emit_subagent_notice_forwards_to_active_loop
    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) do |msg|
      received << msg
    end

    shell_class = Class.new do
      include Rubik::REPL::Lifecycle

      attr_accessor :active_loop, :output, :subagent_notices_mutex, :subagent_notices

      def initialize(mock_loop)
        @active_loop = mock_loop
        @output = StringIO.new
        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
      end
    end

    shell = shell_class.new(mock_loop)
    shell.emit_subagent_notice("⚡ Test Notice")

    assert_equal ["⚡ Test Notice"], received
    assert_equal ["⚡ Test Notice"], shell.subagent_notices
  end
end
