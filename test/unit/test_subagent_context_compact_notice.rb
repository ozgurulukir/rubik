# frozen_string_literal: true

require "stringio"
require_relative "../test_helper"

# Pins for the subagent emergency-compaction notice (Candidate 03): the
# subagent recovery path — previously silent — announces on the bus, flows
# through the Notices vocabulary on both channels, and auto-subscribes the
# REPL via EVENTS.keys (zero repl code changes).
class TestSubagentContextCompactNotice < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def payload
    { id: "subagent-7", role: "Researcher", state: :running,
      reason: "HTTP 400: prompt is too long", layer: :structural }
  end

  def test_events_map_includes_the_compacted_event
    assert_includes Rubik::Orchestrator::Subagent::Notices::EVENTS.keys, :subagent_context_compacted
  end

  def test_normalize_routes_and_caps_reason
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(
      :subagent_context_compacted, payload.merge(reason: "x" * 500)
    )

    assert_equal :context_compacted, notice[:kind]
    assert_equal "subagent-7", notice[:id]
    assert_equal "running", notice[:state]
    assert_equal 120, notice[:reason].length, "provider error text is capped at 120 chars"
  end

  def test_user_line_reports_recovery_without_tool_syntax
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(:subagent_context_compacted, payload)
    line = Rubik::Orchestrator::Subagent::Notices.user_line(notice)

    assert_includes line, "[Subagent Compacted]"
    assert_includes line, "subagent-7"
    assert_includes line, "Researcher"
    assert_includes line, "prompt is too long"
    refute_includes line, "manage_subagents", "nothing to do — no tool call advertised"
  end

  def test_model_element_is_semantic_xml_in_the_notification_block
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(:subagent_context_compacted, payload)
    element = Rubik::Orchestrator::Subagent::Notices.model_element(notice)

    assert element.start_with?("<notification ") && element.end_with?(" />")
    assert_includes element, 'kind="context_compacted"'
    assert_includes element, 'reason="HTTP 400: prompt is too long"'
    assert_includes element, "No action needed"
    refute_includes element, "!subagents", "REPL syntax never reaches the model channel"

    # Quotes in provider error text must stay XML-escaped inside the attribute.
    quoted = Rubik::Orchestrator::Subagent::Notices.normalize(
      :subagent_context_compacted, payload.merge(reason: 'said "too long" already')
    )
    assert_includes Rubik::Orchestrator::Subagent::Notices.model_element(quoted),
                    "said &quot;too long&quot; already"

    block = Rubik::Orchestrator::Subagent::Notices.history_block([notice])
    assert_includes block, "<subagent_notifications>"
    assert_includes block, "<notification "
  end

  def test_instance_recovery_emits_the_bus_event_end_to_end
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, _opts = {}|
      call_count += 1
      raise StandardError, "context_length_exceeded: maximum context length is 32768 tokens" if call_count == 1

      Struct.new(:text, :tool_calls).new("Recovered", [])
    end

    bus = Rubik::EventBus.new
    emitted = []
    bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPACTED_EVENT) { |p| emitted << p }

    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-cx", parent_id: "agent-0", role: "Compacted Worker",
      type_name: "research", prompt: "Overflow", context: @root_context,
      tool_registry: nil, provider: provider, context_limit: 2_000,
      event_bus: bus, root_dir: @ws_root
    )
    10.times do |i|
      inst.history << { role: "user", content: "Turn #{i}: #{'test ' * 80}" }
    end
    # Recovery runs mid-execution on the worker thread; this test occupies
    # that seat on the main thread — the legal pending -> running flip.
    inst.transition!(:running)

    res = inst.send(:invoke_provider_with_recovery, {})

    assert_equal 2, call_count
    assert_equal "Recovered", res.text
    assert_operator inst.history.size, :<, 20, "history must shrink after emergency compaction"

    assert_equal 1, emitted.size
    assert_equal "subagent-cx", emitted.first[:id]
    assert_equal :running, emitted.first[:state]
    assert_includes emitted.first[:reason], "context_length_exceeded"
    assert_includes [:structural, :hard_truncate], emitted.first[:layer]
  end

  def test_shell_routing_auto_subscribes_the_new_event
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(output: out)
    # The routing gate reads @running (only Shell#run sets it); drive the seam
    # as a running shell would.
    shell.instance_variable_set(:@running, true)

    received = []
    mock_loop = Object.new
    mock_loop.define_singleton_method(:enqueue_subagent_notice) { |notice| received << notice }
    shell.instance_variable_set(:@active_loop, mock_loop)

    shell.event_bus.emit(Rubik::Orchestrator::Subagent::Notices::COMPACTED_EVENT, payload)

    assert_equal 1, received.size
    assert_equal :context_compacted, received.first[:kind]

    # End of turn clears @active_loop and flushes the buffered user channel
    shell.instance_variable_set(:@active_loop, nil)
    shell.flush_subagent_notices!

    assert_includes out.string, "[Subagent Compacted]"
    shell.stop
  end
end
