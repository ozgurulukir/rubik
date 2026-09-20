# frozen_string_literal: true

require_relative "../test_helper"

# Regression pin for the Candidate 03 stream-retry fix: a mid-stream context
# overflow must not pollute the retried response with the failed attempt's
# already-delivered chunks.
class TestStreamRetryResetsAttemptState < Minitest::Test
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
  end

  # Delivers real text chunks and THEN fails with an overflow error on the
  # first call (the old tests always raised before any chunk arrived, which
  # is why the pollution went unnoticed); clean chunks on the retry.
  class MidStreamOverflowProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_calls

    def initialize
      super
      @stream_calls = 0
    end

    def stream_chat(_messages, _opts = {}, &block)
      @stream_calls += 1
      if @stream_calls == 1
        block.call(Rubik::LLM::Chunk.new(text_delta: "stale prefix "))
        raise Rubik::LLM::ClientError, "maximum context length exceeded mid-stream"
      end

      block.call(Rubik::LLM::Chunk.new(text_delta: "clean"))
      block.call(Rubik::LLM::Chunk.new(usage: { input_tokens: 5, output_tokens: 2 }, done: true))
    end
  end

  def test_retry_discards_first_attempt_chunks
    provider = MidStreamOverflowProvider.new
    events = []
    loop_obj = MockStreamLoop.new(provider: provider, on_step: ->(info) { events << info })
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    res = manager.execute_streaming_request({})

    assert_equal 2, provider.stream_calls, "exactly one retry"
    assert_equal "clean", res.text, "the retry must assemble only its own chunks"
    assert res.streamed, "streamed flag reflects the successful attempt"
    assert(events.any? { |e| e[:type] == :emergency_compact })
  end

  # Overflows on EVERY call: the retry-once ceiling must also hold at the
  # StreamManager level, not just inside ProviderRecovery.
  class AlwaysOverflowProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_calls

    def initialize
      super
      @stream_calls = 0
    end

    def stream_chat(_messages, _opts = {}, &block)
      @stream_calls += 1
      block.call(Rubik::LLM::Chunk.new(text_delta: "partial "))
      raise Rubik::LLM::ClientError, "maximum context length exceeded"
    end
  end

  def test_second_overflow_escapes_after_single_retry
    provider = AlwaysOverflowProvider.new
    events = []
    loop_obj = MockStreamLoop.new(provider: provider, on_step: ->(info) { events << info })
    manager = Rubik::Orchestrator::StreamManager.new(loop_obj)

    assert_raises(Rubik::LLM::ClientError) do
      manager.execute_streaming_request({})
    end

    assert_equal 2, provider.stream_calls, "no infinite retry at the stream level"
    assert_equal(1, events.count { |e| e[:type] == :emergency_compact })
  end
end
