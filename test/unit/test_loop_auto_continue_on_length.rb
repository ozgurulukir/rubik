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

  def test_process_step_response_auto_continues_on_thinking_exhaustion
    mock_loop = Rubik::Orchestrator::Loop.allocate
    mock_loop.instance_variable_set(:@config, @config)
    mock_loop.instance_variable_set(:@step_count, 1)
    mock_loop.instance_variable_set(:@max_steps, 10)
    mock_loop.instance_variable_set(:@max_output_tokens, 4096)
    mock_loop.instance_variable_set(:@history, [])
    mock_loop.instance_variable_set(:@total_tokens, { input: 10, output: 4096 })
    mock_loop.instance_variable_set(:@budget_manager, Object.new)
    def (mock_loop.instance_variable_get(:@budget_manager)).track_token_usage!(_); end

    step_events = []
    mock_loop.instance_variable_set(:@on_step, ->(event) { step_events << event })

    # Model returned finish_reason length with empty text (thinking exhausted)
    resp = Rubik::LLM::Response.new(
      text: "",
      raw: { "finish_reason" => "length" },
      thought: "I was thinking very deeply about the problem..."
    )

    result = mock_loop.turn_executor.call(resp)
    # process_step_response returns nil to signal that the turn should continue
    assert_nil result

    history = mock_loop.instance_variable_get(:@history)
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
    mock_loop = Rubik::Orchestrator::Loop.allocate
    mock_loop.instance_variable_set(:@config, @config)
    mock_loop.instance_variable_set(:@step_count, 1)
    mock_loop.instance_variable_set(:@max_steps, 10)
    mock_loop.instance_variable_set(:@max_output_tokens, 4096)
    mock_loop.instance_variable_set(:@history, [])
    mock_loop.instance_variable_set(:@total_tokens, { input: 10, output: 4096 })
    mock_loop.instance_variable_set(:@last_turn_streamed, false)
    mock_loop.instance_variable_set(:@budget_manager, Object.new)
    def (mock_loop.instance_variable_get(:@budget_manager)).track_token_usage!(_); end

    step_events = []
    mock_loop.instance_variable_set(:@on_step, ->(event) { step_events << event })

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
    mock_loop = Rubik::Orchestrator::Loop.allocate
    mock_loop.instance_variable_set(:@config, @config)
    mock_loop.instance_variable_set(:@step_count, 1)
    mock_loop.instance_variable_set(:@max_steps, 10)
    mock_loop.instance_variable_set(:@max_output_tokens, 4096)
    mock_loop.instance_variable_set(:@history, [])
    mock_loop.instance_variable_set(:@total_tokens, { input: 10, output: 4096 })
    mock_loop.instance_variable_set(:@budget_manager, Object.new)
    def (mock_loop.instance_variable_get(:@budget_manager)).track_token_usage!(_); end

    # Simulate 3 auto continues already executed
    mock_loop.continuation_manager.instance_variable_set(:@auto_continue_count, 3)

    resp = Rubik::LLM::Response.new(
      text: "Still cutting off...",
      raw: { "finish_reason" => "length" }
    )

    res = mock_loop.turn_executor.call(resp)
    refute res[:ok]
    assert_includes res[:error], "3 otomatik devam denemesi tükendiği için durduruldu"
    assert_includes res[:error], "!config set llm.default_max_output_tokens 8192"
  end
end
