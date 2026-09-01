# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestStreamManager < Minitest::Test
  # Minimal stand-in for Rubik::Orchestrator::Loop carrying only the state
  # StreamManager reads through accessors.
  class MockStreamLoop
    attr_accessor :step_count, :max_steps, :history, :last_turn_streamed,
                  :config, :context_limit, :max_output_tokens, :total_tokens,
                  :context_warning_emitted
    attr_reader :provider, :on_step, :budget_manager

    def initialize(provider:, on_step: nil)
      @provider = provider
      @on_step = on_step
      @step_count = 1
      @max_steps = 40
      @history = []
      @total_tokens = { input: 0, output: 0 }
      @last_turn_streamed = false
      @context_warning_emitted = false
      @config = nil
      @context_limit = 32_768
      @max_output_tokens = 4_096
      @budget_manager = MockBudgetManager.new
    end

    def emergency_compact_and_notify!(msg)
      @on_step&.call(type: :emergency_compact, message: msg, step: @step_count, max_steps: @max_steps)
      @history.clear
    end
  end

  class MockBudgetManager
    def estimate_tokens_from_history
      100
    end

    def track_token_usage!(_res); end
  end

  # Provider that delivers a fixed sequence of chunks + optional error
  class MockStreamProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_calls

    def initialize(chunks:, error_on_first_stream: nil, estimate_tokens_fn: nil)
      super()
      @chunks = chunks
      @error_on_first_stream = error_on_first_stream
      @stream_calls = 0
      @estimate_tokens_fn = estimate_tokens_fn
    end

    def stream_chat(_messages, _opts = {}, &block)
      @stream_calls += 1
      raise Rubik::LLM::ClientError, @error_on_first_stream if @error_on_first_stream && @stream_calls == 1

      if block
        @chunks.each { |c| block.call(c) }
      else
        @chunks.to_enum
      end
    end

    def estimate_tokens(text)
      @estimate_tokens_fn ? @estimate_tokens_fn.call(text) : (text.to_s.length / 4.0).ceil
    end
  end

  def setup
    @events = []
    @on_step = ->(info) { @events << info }
  end

  # ── execute_streaming_request ──────────────────────────────────────

  def test_delivers_text_deltas_as_chunk_events
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Hello "),
      Rubik::LLM::Chunk.new(text_delta: "world"),
      Rubik::LLM::Chunk.new(text_delta: "!"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 4 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.execute_streaming_request({})

    assert_kind_of Rubik::LLM::Response, res
    assert_equal "Hello world!", res.text
    assert_equal 10, res.usage[:input_tokens]
    assert_equal 4, res.usage[:output_tokens]
    assert res.streamed

    deltas = @events.select { |e| e[:type] == :chunk }.map { |e| e[:delta] }
    assert_equal ["Hello ", "world", "!"], deltas
    assert(@events.any? { |e| e[:type] == :chunk_end })
  end

  def test_streaming_tool_calls_do_not_emit_text_chunks
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: [
                              { "index" => 0, "name" => "finish", "arguments_delta" => '{"message":"done"}' }
                            ]),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 5, output_tokens: 2 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.execute_streaming_request({})

    assert res.tool_calls?
    assert_equal "finish", res.tool_calls.first["tool"]
    # No text deltas → no chunk events, no chunk_end
    assert_empty(@events.select { |e| e[:type] == :chunk })
    refute(@events.any? { |e| e[:type] == :chunk_end })
  end

  def test_handles_enumerator_when_no_block_given
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Enum "),
      Rubik::LLM::Chunk.new(text_delta: "output"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 3, output_tokens: 2 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    # Stub stream_chat to return Enumerator when block is nil
    original = provider.method(:stream_chat)
    provider.define_singleton_method(:stream_chat) do |msgs, opts = {}, &block|
      if block
        original.call(msgs, opts, &block)
      else
        @chunks.to_enum
      end
    end

    res = manager.execute_streaming_request({})

    assert_equal "Enum output", res.text
    # Chunks from Enumerator path still emit events
    deltas = @events.select { |e| e[:type] == :chunk }.map { |e| e[:delta] }
    assert_equal ["Enum ", "output"], deltas
  end

  def test_retries_once_on_context_overflow_error
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "After retry"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 5, output_tokens: 2 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks, error_on_first_stream: "maximum context length exceeded")
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.execute_streaming_request({})

    assert_equal "After retry", res.text
    assert_equal 2, provider.stream_calls, "should retry once"
    assert(@events.any? { |e| e[:type] == :emergency_compact })
  end

  def test_does_not_retry_on_non_context_error
    chunks = [Rubik::LLM::Chunk.new(text_delta: "won't reach")]
    provider = MockStreamProvider.new(chunks: chunks, error_on_first_stream: "rate limit exceeded")
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    assert_raises(Rubik::LLM::ClientError) do
      manager.execute_streaming_request({})
    end
    assert_equal 1, provider.stream_calls
  end

  def test_does_not_catch_interrupt
    chunks = [Rubik::LLM::Chunk.new(text_delta: "x")]
    provider = MockStreamProvider.new(chunks: chunks, error_on_first_stream: "context")
    # Override stream_chat to raise Interrupt
    provider.define_singleton_method(:stream_chat) do |*|
      raise Interrupt, "Ctrl+C"
    end
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    assert_raises(Interrupt) do
      manager.execute_streaming_request({})
    end
  end

  def test_retry_disabled_when_config_says_no
    chunks = [Rubik::LLM::Chunk.new(text_delta: "x")]
    provider = MockStreamProvider.new(chunks: chunks, error_on_first_stream: "context length")
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    loop_obj.config = { "context.auto_recover_on_overflow" => false }
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    assert_raises(Rubik::LLM::ClientError) do
      manager.execute_streaming_request({})
    end
    assert_equal 1, provider.stream_calls
  end

  # ── build_response_from_chunks ─────────────────────────────────────

  def test_builds_response_from_chunks_directly
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Direct "),
      Rubik::LLM::Chunk.new(text_delta: "output"),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "call_1", "name" => "finish",
                                              "arguments_delta" => '{"message":"done"}' }),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 7, output_tokens: 3 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: [])
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.build_response_from_chunks(chunks, streamed_text: true)

    assert_equal "Direct output", res.text
    assert_equal 1, res.tool_calls.size
    assert_equal "finish", res.tool_calls.first["tool"]
    assert_equal({ "message" => "done" }, res.tool_calls.first["args"])
    assert_equal 7, res.usage[:input_tokens]
    assert res.streamed
  end

  def test_build_response_without_streamed_flag
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "batch"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 2, output_tokens: 1 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: [])
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.build_response_from_chunks(chunks)

    refute res.streamed
    assert_equal "batch", res.text
  end

  def test_on_malformed_args_callback_fires
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: [
                              { "index" => 0, "name" => "read_file", "arguments_delta" => "{invalid json}" }
                            ]),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 5, output_tokens: 1 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: [])
    loop_obj = MockStreamLoop.new(provider: provider, on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.build_response_from_chunks(chunks, streamed_text: false)

    assert res.tool_calls?
    # Malformed args → empty {} fallback
    assert_equal({}, res.tool_calls.first["args"])
    # on_step received malformed_tool_args event
    assert(@events.any? { |e| e[:type] == :malformed_tool_args })
  end

  # ── llm_retry_notifier ─────────────────────────────────────────────

  def test_retry_notifier_forwards_to_on_step
    loop_obj = MockStreamLoop.new(provider: MockStreamProvider.new(chunks: []), on_step: @on_step)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)
    notifier = manager.llm_retry_notifier

    notifier.call(2, 5, "rate limited")

    assert_equal 1, @events.size
    assert_equal :llm_retry, @events.first[:type]
    assert_equal 2, @events.first[:attempt]
    assert_equal 5, @events.first[:max]
    assert_equal "rate limited", @events.first[:reason]
  end

  def test_retry_notifier_noop_when_on_step_nil
    loop_obj = MockStreamLoop.new(provider: MockStreamProvider.new(chunks: []), on_step: nil)
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)
    notifier = manager.llm_retry_notifier

    # Should not raise
    notifier.call(1, 3, "timeout")
    assert_empty @events
  end
end
