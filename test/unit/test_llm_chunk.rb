# frozen_string_literal: true

require_relative "../test_helper"

# Tests for the streaming foundation introduced in PR-A:
#   - `Rubik::LLM::Chunk` value object
#   - `Rubik::LLM::BaseProvider#stream_chat` (abstract)
#   - `Rubik::LLM::BaseProvider#complete` fallback that aggregates chunks
class TestLLMChunk < Minitest::Test
  # ---------- Chunk value object ----------

  def test_chunk_default_values
    chunk = Rubik::LLM::Chunk.new
    assert_nil chunk.text_delta
    assert_nil chunk.tool_use_delta
    assert_nil chunk.usage
    refute chunk.done?
    assert_equal({}, chunk.raw)
  end

  def test_chunk_with_text_delta
    chunk = Rubik::LLM::Chunk.new(text_delta: "hello")
    assert chunk.text_delta?
    assert_equal "hello", chunk.text_delta
    refute chunk.tool_use_delta?
    refute chunk.done?
  end

  def test_chunk_with_tool_use_delta
    tool_delta = { "index" => 0, "id" => "tool_1", "name" => "get_weather" }
    chunk = Rubik::LLM::Chunk.new(tool_use_delta: tool_delta)
    assert chunk.tool_use_delta?
    refute chunk.text_delta?
    assert_equal tool_delta, chunk.tool_use_delta
  end

  def test_chunk_with_usage
    usage = { input_tokens: 10, output_tokens: 5 }
    chunk = Rubik::LLM::Chunk.new(usage: usage)
    assert_equal usage, chunk.usage
  end

  def test_chunk_with_done_flag
    chunk = Rubik::LLM::Chunk.new(done: true)
    assert chunk.done?
  end

  def test_chunk_with_raw_payload
    raw = { "model" => "claude-3-7-sonnet", "stop_reason" => "end_turn" }
    chunk = Rubik::LLM::Chunk.new(raw: raw)
    assert_equal raw, chunk.raw
  end

  # ---------- BaseProvider#stream_chat abstract ----------

  def test_stream_chat_raises_not_implemented_on_base_provider
    provider = Rubik::LLM::BaseProvider.new
    assert_raises(NotImplementedError) do
      provider.stream_chat([{ role: "user", content: "hi" }])
    end
  end

  # ---------- BaseProvider#complete fallback ----------

  # Helper: a minimal concrete provider that only implements #stream_chat.
  # Used to verify the `complete` fallback wires up correctly.
  class StreamOnlyProvider < Rubik::LLM::BaseProvider
    def stream_chat(_messages, _opts = {}, &block)
      block.call(Rubik::LLM::Chunk.new(text_delta: "Hi"))
      block.call(Rubik::LLM::Chunk.new(text_delta: " there"))
      block.call(Rubik::LLM::Chunk.new(text_delta: "!"))
      block.call(Rubik::LLM::Chunk.new(
                   done: true,
                   usage: { input_tokens: 7, output_tokens: 3 },
                   raw: { "model" => "stub", "stop_reason" => "end_turn" }
                 ))
      :finished
    end
  end

  def test_complete_fallback_joins_text_deltas
    provider = StreamOnlyProvider.new
    res = provider.complete([{ role: "user", content: "hi" }])
    assert_kind_of Rubik::LLM::Response, res
    assert_equal "Hi there!", res.text
  end

  def test_complete_fallback_picks_usage_from_done_chunk
    provider = StreamOnlyProvider.new
    res = provider.complete([{ role: "user", content: "hi" }])
    assert_equal 7, res.usage[:input_tokens]
    assert_equal 3, res.usage[:output_tokens]
  end

  def test_complete_fallback_picks_raw_from_done_chunk
    provider = StreamOnlyProvider.new
    res = provider.complete([{ role: "user", content: "hi" }])
    assert_equal "stub", res.raw["model"]
    assert_equal "end_turn", res.raw["stop_reason"]
  end

  def test_complete_fallback_handles_empty_chunks
    empty_provider_class = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {})
        # yields nothing
        :finished
      end
    end
    provider = empty_provider_class.new
    res = provider.complete([{ role: "user", content: "hi" }])
    assert_equal "", res.text
    assert_equal({}, res.usage)
  end

  def test_complete_fallback_handles_enumerator_returned_by_stream_chat
    # If stream_chat returns an Enumerator (no block given), the fallback
    # should drain it. This test exercises that path with a provider that
    # does NOT yield to a block but returns an Enumerator.
    enum_provider_class = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(_messages, _opts = {}, &block)
        return enum_for(:__stream_enum) unless block

        __stream_enum.each(&block)
      end

      def __stream_enum
        Enumerator.new do |y|
          y << Rubik::LLM::Chunk.new(text_delta: "A")
          y << Rubik::LLM::Chunk.new(text_delta: "B")
          y << Rubik::LLM::Chunk.new(done: true, usage: { input_tokens: 1, output_tokens: 2 })
        end
      end
    end
    provider = enum_provider_class.new
    res = provider.complete([{ role: "user", content: "hi" }])
    assert_equal "AB", res.text
    assert_equal 2, res.usage[:output_tokens]
  end
end
