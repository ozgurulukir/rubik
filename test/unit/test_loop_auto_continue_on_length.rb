# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/loop"
require_relative "../../lib/rubik/llm/provider"

class TestLoopAutoContinueOnLength < Minitest::Test
  def setup
    @config = { "llm" => { "auto_continue_on_length" => true, "max_auto_continues" => 3 } }
    shell_struct = Struct.new(:config, :buffer_manager, :snapshot_store, :context_index, :lsp_manager, :runtime_manager, :commands)
    @shell = shell_struct.new(@config, nil, nil, nil, nil, nil, nil)
  end

  # Fixture built through the public constructor (fake shell supplies the
  # config coeffect); truncation behavior is asserted off the turn result,
  # the public history reader, the emitted step events and the public
  # ContinuationManager readers — no bare Loop instances.
  def build_auto_continue_loop(on_step:)
    tool_registry = Struct.new(:schemas).new([])
    tool_registry.define_singleton_method(:get) { |_name| nil }

    Rubik::Orchestrator::Loop.new(
      provider: Object.new,
      tool_registry: tool_registry,
      max_steps: 10,
      on_step: on_step,
      shell: @shell,
      max_output_tokens: 4096
    )
  end

  def test_process_step_response_auto_continues_on_thinking_exhaustion
    step_events = []
    mock_loop = build_auto_continue_loop(on_step: ->(event) { step_events << event })

    # Model returned finish_reason length with empty text (thinking exhausted)
    resp = Rubik::LLM::Response.new(
      text: "",
      raw: { "finish_reason" => "length" },
      thought: "I was thinking very deeply about the problem..."
    )

    result = mock_loop.turn_executor.call(resp)
    # process_step_response returns nil to signal that the turn should continue
    assert_nil result

    history = mock_loop.history
    assert_equal 2, history.size
    assert_equal "assistant", history[0][:role]
    assert_equal "I was thinking very deeply about the problem...", history[0][:thought]
    assert_equal "user", history[1][:role]
    assert_includes history[1][:content], "thinking process reached the output token limit"

    # Step event was emitted
    assert_equal 1, step_events.size
    assert_equal :auto_continue, step_events[0][:type]
    assert_equal :thinking_exhausted, step_events[0][:reason]
  end

  def test_process_step_response_auto_continues_and_stitches_partial_text
    step_events = []
    mock_loop = build_auto_continue_loop(on_step: ->(event) { step_events << event })

    # Step 1: Model text was cut off mid-sentence
    resp1 = Rubik::LLM::Response.new(
      text: "class Calculator\n  def add(a, b)\n",
      raw: { "finish_reason" => "length" }
    )

    res1 = mock_loop.turn_executor.call(resp1)
    assert_nil res1
    assert_equal 1, mock_loop.continuation_manager.auto_continue_count
    assert_equal "class Calculator\n  def add(a, b)\n", mock_loop.continuation_manager.continuation_buffer

    # Step 2: Model finishes the text with stop reason
    resp2 = Rubik::LLM::Response.new(
      text: "    a + b\n  end\nend",
      raw: { "finish_reason" => "stop" }
    )

    res2 = mock_loop.turn_executor.call(resp2)
    assert res2[:ok]
    expected = "class Calculator\n  def add(a, b)\n    a + b\n  end\nend"
    assert_equal expected, res2[:output]
    assert_equal 0, mock_loop.continuation_manager.auto_continue_count
  end

  def test_process_step_response_aborts_when_ceiling_exhausted
    mock_loop = build_auto_continue_loop(on_step: ->(_event) {})

    # Drive 3 real auto-continues (the configured ceiling) instead of
    # poking the manager's counter, then show the next truncation aborts.
    truncated = Rubik::LLM::Response.new(text: "Still cutting off...", raw: { "finish_reason" => "length" })
    3.times do |i|
      res = mock_loop.turn_executor.call(truncated)
      assert_nil res
      assert_equal i + 1, mock_loop.continuation_manager.auto_continue_count
    end

    res = mock_loop.turn_executor.call(truncated)
    refute res[:ok]
    assert_includes res[:error], "3 automatic continue attempts were exhausted, so it was stopped"
    assert_includes res[:error], "!config set llm.default_max_output_tokens 8192"
  end
end
