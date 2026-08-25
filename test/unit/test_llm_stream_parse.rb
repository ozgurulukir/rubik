# frozen_string_literal: true

require_relative "../test_helper"

# Tests for `Formatter#parse_stream_event` introduced in PR-C.
# Each provider's SSE/NDJSON format is normalized into a `Chunk`.
class TestLLMStreamParse < Minitest::Test
  # ---------- BaseFormatter default ----------

  def test_base_formatter_parse_returns_nil
    chunk = Rubik::LLM::BaseFormatter.parse_stream_event(type: "message", data: "anything")
    assert_nil chunk
  end

  # ---------- OpenAIFormatter ----------

  def test_openai_text_delta
    data = JSON.dump({
      "id" => "chatcmpl-1",
      "choices" => [{ "delta" => { "content" => "Hello" } }]
    })
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data)
    assert_kind_of Rubik::LLM::Chunk, chunk
    assert chunk.text_delta?
    assert_equal "Hello", chunk.text_delta
    refute chunk.done?
  end

  def test_openai_multiple_text_deltas_accumulate_via_caller
    data1 = JSON.dump("choices" => [{ "delta" => { "content" => "Hi" } }])
    data2 = JSON.dump("choices" => [{ "delta" => { "content" => " there" } }])
    c1 = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data1)
    c2 = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data2)
    assert_equal "Hi", c1.text_delta
    assert_equal " there", c2.text_delta
  end

  def test_openai_done_marker
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: "[DONE]")
    assert_kind_of Rubik::LLM::Chunk, chunk
    assert chunk.done?
  end

  def test_openai_finish_reason_marks_done
    data = JSON.dump("choices" => [{ "delta" => {}, "finish_reason" => "stop" }])
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data)
    assert chunk.done?
  end

  def test_openai_usage_includes_prompt_completion_tokens
    data = JSON.dump(
      "choices" => [{ "delta" => {}, "finish_reason" => "stop" }],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15 }
    )
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data)
    assert chunk.done?
    assert_equal 10, chunk.usage[:input_tokens]
    assert_equal 5, chunk.usage[:output_tokens]
  end

  def test_openai_tool_call_delta
    data = JSON.dump("choices" => [{
      "delta" => {
        "tool_calls" => [{
          "index" => 0,
          "id" => "call_1",
          "function" => { "name" => "get_weather", "arguments" => "{\"city\":" }
        }]
      }
    }])
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data)
    assert chunk.tool_use_delta?
    assert_equal "call_1", chunk.tool_use_delta.first["id"]
    assert_equal "get_weather", chunk.tool_use_delta.first["name"]
    assert_equal "{\"city\":", chunk.tool_use_delta.first["arguments_delta"]
  end

  def test_openai_malformed_json_returns_nil
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: "{not json")
    assert_nil chunk
  end

  def test_openai_empty_choices_returns_nil
    data = JSON.dump("choices" => [])
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: data)
    assert_nil chunk
  end

  def test_openai_empty_data_returns_nil
    chunk = Rubik::LLM::OpenAIFormatter.parse_stream_event(type: "message", data: "")
    assert_nil chunk
  end

  # ---------- AnthropicFormatter ----------

  def test_anthropic_text_delta
    data = JSON.dump("delta" => { "type" => "text_delta", "text" => "Hello" })
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "content_block_delta", data: data
    )
    assert chunk.text_delta?
    assert_equal "Hello", chunk.text_delta
  end

  def test_anthropic_tool_use_delta
    data = JSON.dump(
      "index" => 0,
      "delta" => { "type" => "input_json_delta", "partial_json" => "{\"city\":" }
    )
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "content_block_delta", data: data
    )
    assert chunk.tool_use_delta?
    assert_equal 0, chunk.tool_use_delta["index"]
    assert_equal "{\"city\":", chunk.tool_use_delta["arguments_delta"]
  end

  def test_anthropic_message_delta_carries_usage
    data = JSON.dump("usage" => { "input_tokens" => 12, "output_tokens" => 7 })
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "message_delta", data: data
    )
    assert_equal 12, chunk.usage["input_tokens"]
    assert_equal 7, chunk.usage["output_tokens"]
  end

  def test_anthropic_message_stop_marks_done
    data = JSON.dump("stop_reason" => "end_turn")
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "message_stop", data: data
    )
    assert chunk.done?
  end

  def test_anthropic_ping_event_returns_nil
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "ping", data: "{}"
    )
    assert_nil chunk
  end

  def test_anthropic_error_event_raises_client_error
    data = JSON.dump("error" => { "message" => "rate limit exceeded" })
    assert_raises(Rubik::LLM::ClientError) do
      Rubik::LLM::AnthropicFormatter.parse_stream_event(type: "error", data: data)
    end
  end

  def test_anthropic_malformed_json_returns_nil
    chunk = Rubik::LLM::AnthropicFormatter.parse_stream_event(
      type: "content_block_delta", data: "{not json"
    )
    assert_nil chunk
  end

  # ---------- OllamaFormatter (NDJSON) ----------

  def test_ollama_text_delta
    data = JSON.dump("model" => "llama3", "response" => "Hello", "done" => false)
    chunk = Rubik::LLM::OllamaFormatter.parse_stream_event(type: "message", data: data)
    assert chunk.text_delta?
    assert_equal "Hello", chunk.text_delta
    refute chunk.done?
  end

  def test_ollama_done_line_marks_done_with_usage
    data = JSON.dump(
      "model" => "llama3",
      "response" => "",
      "done" => true,
      "prompt_eval_count" => 20,
      "eval_count" => 8
    )
    chunk = Rubik::LLM::OllamaFormatter.parse_stream_event(type: "message", data: data)
    assert chunk.done?
    assert_equal 20, chunk.usage[:input_tokens]
    assert_equal 8, chunk.usage[:output_tokens]
  end

  def test_ollama_empty_response_field_no_text_delta
    data = JSON.dump("model" => "llama3", "response" => "", "done" => false)
    chunk = Rubik::LLM::OllamaFormatter.parse_stream_event(type: "message", data: data)
    refute chunk.text_delta?
    refute chunk.done?
  end

  def test_ollama_malformed_json_returns_nil
    chunk = Rubik::LLM::OllamaFormatter.parse_stream_event(type: "message", data: "not json")
    assert_nil chunk
  end

  def test_ollama_empty_data_returns_nil
    chunk = Rubik::LLM::OllamaFormatter.parse_stream_event(type: "message", data: "")
    assert_nil chunk
  end
end
