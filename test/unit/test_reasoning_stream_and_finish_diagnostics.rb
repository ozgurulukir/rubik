# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/provider"
require "rubik/llm/formatter"
require "rubik/llm/chunk_assembler"
require "rubik/orchestrator/loop"
require "rubik/orchestrator/stream_manager"

class TestReasoningStreamAndFinishDiagnostics < Minitest::Test
  FakeShell = Struct.new(:config, :buffer_manager, :snapshot_store, :context_index,
                         :lsp_manager, :runtime_manager, keyword_init: true)
  FakeToolRegistry = Struct.new(:schemas)

  def setup
    @formatter = Rubik::LLM::OpenAIFormatter.new
  end

  # Fixture built through the public constructor (fake shell supplies the
  # config coeffect) instead of a Loop.allocate bare instance — the
  # diagnostics under test are asserted behaviorally off the turn result,
  # the emitted on_step events and the public history reader.
  def build_diagnostic_loop(config:, max_output_tokens:, on_step:)
    registry = FakeToolRegistry.new([])
    registry.define_singleton_method(:get) { |_name| nil }

    Rubik::Orchestrator::Loop.new(
      provider: Object.new,
      tool_registry: registry,
      max_steps: 20,
      on_step: on_step,
      shell: FakeShell.new(config: config),
      max_output_tokens: max_output_tokens
    )
  end

  def test_formatter_parses_reasoning_content_delta
    event = { type: "message", data: '{"choices":[{"delta":{"reasoning_content":"Thinking deeply..."}}]}' }
    chunk = @formatter.parse_stream_event(event)

    assert chunk.reasoning_delta?
    assert_equal "Thinking deeply...", chunk.reasoning_delta
    assert_nil chunk.text_delta
  end

  def test_formatter_parses_reasoning_and_thought_aliases
    event1 = { type: "message", data: '{"choices":[{"delta":{"reasoning":"Step 1"}}]}' }
    chunk1 = @formatter.parse_stream_event(event1)
    assert_equal "Step 1", chunk1.reasoning_delta

    event2 = { type: "message", data: '{"choices":[{"delta":{"thought":"Step 2"}}]}' }
    chunk2 = @formatter.parse_stream_event(event2)
    assert_equal "Step 2", chunk2.reasoning_delta
  end

  def test_formatter_preserves_usage_when_choices_empty
    event = { type: "message", data: '{"choices":[],"usage":{"prompt_tokens":25,"completion_tokens":50}}' }
    chunk = @formatter.parse_stream_event(event)

    refute_nil chunk
    assert chunk.done?
    assert_equal({ input_tokens: 25, output_tokens: 50 }, chunk.usage)
  end

  def test_chunk_assembler_accumulates_thought
    chunks = [
      Rubik::LLM::Chunk.new(reasoning_delta: "First thought. "),
      Rubik::LLM::Chunk.new(reasoning_delta: "Second thought."),
      Rubik::LLM::Chunk.new(text_delta: "Final answer."),
      Rubik::LLM::Chunk.new(raw: { "choices" => [{ "finish_reason" => "stop" }] }, done: true)
    ]

    res = Rubik::LLM::ChunkAssembler.build(chunks, streamed: true)
    assert_equal "First thought. Second thought.", res.thought
    assert_equal "Final answer.", res.text
  end

  def test_chunk_assembler_preserves_finish_reason_with_trailing_usage_chunk
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Truncated...", raw: { "choices" => [{ "finish_reason" => "length" }] }),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 4096 }, raw: { "choices" => [] }, done: true)
    ]

    res = Rubik::LLM::ChunkAssembler.build(chunks, streamed: true)
    assert_equal "Truncated...", res.text
    assert_equal "length", res.raw["finish_reason"]
    assert_equal({ input_tokens: 10, output_tokens: 4096 }, res.usage)
  end

  def test_stream_manager_emits_llm_thought_delta
    events_emitted = []
    budget = Object.new
    def budget.estimate_tokens_from_history
      10
    end

    fake_loop = Struct.new(:history, :step_count, :max_steps, :on_step, :provider, :last_turn_streamed, :budget_manager, :config).new(
      [], 1, 10, ->(info) { events_emitted << info }, nil, false, budget, nil
    )

    provider = Object.new

    def provider.stream_chat(_history, _opts, &block)
      block.call(Rubik::LLM::Chunk.new(reasoning_delta: "pondering"))
      block.call(Rubik::LLM::Chunk.new(text_delta: "done"))
      block.call(Rubik::LLM::Chunk.new(done: true))
    end

    def provider.respond_to?(method_name)
      method_name == :stream_chat || super
    end

    fake_loop.provider = provider
    sm = Rubik::Orchestrator::StreamManager.new(fake_loop)
    res = sm.execute_streaming_request({})

    thought_events = events_emitted.select { |e| e[:type] == :llm_thought_delta }
    assert_equal 1, thought_events.size
    assert_equal "pondering", thought_events[0][:delta]
    assert_equal "done", res.text
    assert_equal "pondering", res.thought
  end

  def test_finish_reason_length_triggers_elm_style_diagnostic
    error_events = []
    mock_loop = build_diagnostic_loop(
      config: { "llm" => { "auto_continue_on_length" => false } },
      max_output_tokens: 4096,
      on_step: ->(info) { error_events << info if info[:type] == :error }
    )

    response = Rubik::LLM::Response.new(
      text: "",
      raw: { "finish_reason" => "length" },
      streamed: true
    )

    result = mock_loop.turn_executor.call(response)

    refute result[:ok]
    assert_includes result[:error], "reached the maximum token limit (max_output_tokens: 4096) and was cut off before completion"
    assert_includes result[:error], "!config set llm.default_max_output_tokens 8192"
    assert_equal 1, error_events.size
    assert_includes error_events[0][:content], "max_output_tokens: 4096"
  end

  def test_finish_reason_max_tokens_triggers_elm_style_diagnostic
    mock_loop = build_diagnostic_loop(
      config: { "llm" => { "auto_continue_on_length" => false } },
      max_output_tokens: 2048,
      on_step: ->(_info) {}
    )

    response = Rubik::LLM::Response.new(
      text: "",
      raw: { "stop_reason" => "max_tokens" },
      streamed: true
    )

    result = mock_loop.turn_executor.call(response)

    refute result[:ok]
    assert_includes result[:error], "max_output_tokens: 2048"
    assert_includes result[:error], "!config set llm.default_max_output_tokens 4096"
  end

  def test_thought_without_action_sends_smart_reasoning_nudge
    mock_loop = build_diagnostic_loop(
      config: { "llm" => { "auto_continue_on_length" => true } },
      max_output_tokens: 4096,
      on_step: ->(_info) {}
    )
    history = mock_loop.history

    response = Rubik::LLM::Response.new(
      text: "",
      thought: "I planned the whole solution but forgot to call tools.",
      raw: { "finish_reason" => "stop" }
    )

    result = mock_loop.turn_executor.call(response)

    assert_nil result # loop continues
    assert_equal 1, history.size
    expected_nudge = "Your reasoning was completed, but no action or final response was provided. " \
                     "Please call a tool or provide your final output."
    assert_equal expected_nudge, history[0][:content]
  end

  def test_completely_empty_response_sends_standard_nudge
    mock_loop = build_diagnostic_loop(
      config: { "llm" => { "auto_continue_on_length" => true } },
      max_output_tokens: 4096,
      on_step: ->(_info) {}
    )
    history = mock_loop.history

    response = Rubik::LLM::Response.new(
      text: "",
      raw: { "finish_reason" => "stop" }
    )

    result = mock_loop.turn_executor.call(response)

    assert_nil result
    assert_equal 1, history.size
    assert_equal "Your last response was empty. Continue the task or call the finish tool.", history[0][:content]
  end

  def test_anthropic_streaming_delta_stop_reason_preserved_by_chunk_assembler
    c1 = Rubik::LLM::Chunk.new(text_delta: "")
    c2 = Rubik::LLM::Chunk.new(raw: { "type" => "message_delta", "delta" => { "stop_reason" => "max_tokens" } })
    c3 = Rubik::LLM::Chunk.new(done: true, raw: { "type" => "message_stop" })

    response = Rubik::LLM::ChunkAssembler.build([c1, c2, c3])
    assert_equal "max_tokens", response.raw["stop_reason"]
  end
end
