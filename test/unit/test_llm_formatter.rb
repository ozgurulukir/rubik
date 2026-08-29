# frozen_string_literal: true

require_relative "../test_helper"

class TestLLMFormatter < Minitest::Test
  def test_base_formatter_defaults
    formatter = Rubik::LLM::BaseFormatter.new
    msgs = [{ role: "user", content: "hello" }]
    tools = [{ name: "foo" }]

    assert_equal msgs, formatter.format_messages(msgs)
    assert_equal tools, formatter.format_tools(tools)
    assert_equal msgs, Rubik::LLM::BaseFormatter.format_messages(msgs)
    assert_equal tools, Rubik::LLM::BaseFormatter.format_tools(tools)
  end

  def test_openai_formatter_messages_and_tools
    formatter = Rubik::LLM::OpenAIFormatter.new

    messages = [
      { role: "system", content: "System prompt" },
      { role: "user", content: "Call tool" },
      {
        role: "assistant",
        content: "Calling tool",
        tool_calls: [{ "id" => "call_1", "tool" => "read_file", "args" => { "path" => "a.rb" } }]
      },
      { role: "tool", tool_call_id: "call_1", content: "File content" },
      { role: "system", content: "Mid-conversation system notice" }
    ]

    formatted = formatter.format_messages(messages)
    assert_equal "system", formatted[0]["role"]
    assert_equal "System prompt", formatted[0]["content"]

    assert_equal "user", formatted[1]["role"]

    assert_equal "assistant", formatted[2]["role"]
    assert_equal "Calling tool", formatted[2]["content"]
    assert_equal 1, formatted[2]["tool_calls"].size
    assert_equal "call_1", formatted[2]["tool_calls"].first["id"]
    assert_equal "function", formatted[2]["tool_calls"].first["type"]
    assert_equal "read_file", formatted[2]["tool_calls"].first.dig("function", "name")
    assert_equal JSON.generate({ "path" => "a.rb" }), formatted[2]["tool_calls"].first.dig("function", "arguments")

    assert_equal "tool", formatted[3]["role"]
    assert_equal "call_1", formatted[3]["tool_call_id"]
    assert_equal "File content", formatted[3]["content"]

    # Mid-conversation system converted to user with prefix
    assert_equal "user", formatted[4]["role"]
    assert_includes formatted[4]["content"], "[System Notification]"

    tools = [
      {
        name: "test_tool",
        description: "A tool for testing",
        params_schema: { type: "object", properties: { "path" => { type: "string" } } }
      }
    ]

    formatted_tools = formatter.format_tools(tools)
    assert_equal 1, formatted_tools.size
    assert_equal "function", formatted_tools.first[:type]
    assert_equal "test_tool", formatted_tools.first[:function][:name]
  end

  def test_anthropic_formatter_messages_and_tools
    formatter = Rubik::LLM::AnthropicFormatter.new

    messages = [
      { role: "user", content: "Run calc" },
      {
        role: "assistant",
        content: "Calculating...",
        tool_calls: [{ "id" => "call_calc", "tool" => "calculate", "args" => { "expr" => "1+1" } }]
      },
      { role: "tool", tool_call_id: "call_calc", content: "2" }
    ]

    formatted = formatter.format_messages(messages)
    assert_equal "user", formatted[0]["role"]

    assert_equal "assistant", formatted[1]["role"]
    blocks = formatted[1]["content"]
    assert_equal 2, blocks.size
    assert_equal "text", blocks[0]["type"]
    assert_equal "tool_use", blocks[1]["type"]
    assert_equal "call_calc", blocks[1]["id"]
    assert_equal "calculate", blocks[1]["name"]
    assert_equal({ "expr" => "1+1" }, blocks[1]["input"])

    assert_equal "user", formatted[2]["role"]
    tool_res = formatted[2]["content"].first
    assert_equal "tool_result", tool_res["type"]
    assert_equal "call_calc", tool_res["tool_use_id"]
    assert_equal "2", tool_res["content"]

    tools = [
      {
        name: "calculator",
        description: "Evaluate math",
        parameters: { type: "object" }
      }
    ]
    formatted_tools = formatter.format_tools(tools)
    assert_equal "calculator", formatted_tools.first[:name]
    assert_equal({ type: "object" }, formatted_tools.first[:input_schema])
  end

  def test_ollama_formatter_messages_and_tools
    formatter = Rubik::LLM::OllamaFormatter.new

    messages = [
      { role: "user", content: "Do something" },
      {
        role: "assistant",
        content: "I will do it",
        tool_calls: [{ "tool" => "search", "args" => { "q" => "ruby" } }]
      },
      { role: "tool", content: "Search results" }
    ]

    formatted = formatter.format_messages(messages)
    assert_equal "user", formatted[0]["role"]

    assert_equal "assistant", formatted[1]["role"]
    assert_equal "I will do it", formatted[1]["content"]
    assert_equal 1, formatted[1]["tool_calls"].size
    assert_equal "search", formatted[1]["tool_calls"].first["function"]["name"]
    assert_equal({ "q" => "ruby" }, formatted[1]["tool_calls"].first["function"]["arguments"])

    assert_equal "user", formatted[2]["role"]
    assert_equal "Search results", formatted[2]["content"]

    tools = [
      {
        name: "search",
        description: "Search web",
        parameters: { type: "object" }
      }
    ]
    formatted_tools = formatter.format_tools(tools)
    assert_equal "function", formatted_tools.first[:type]
    assert_equal "search", formatted_tools.first[:function][:name]
  end

  # Plan 61 D-14/D-6 regression: a plain user message (step-budget warning,
  # empty-response nudge) landing right after tool results must NOT
  # stringify the tool_result block array — the text folds in as an extra
  # content block so the Anthropic payload stays valid.
  def test_anthropic_plain_user_after_tool_results_appends_text_block
    formatter = Rubik::LLM::AnthropicFormatter.new

    messages = [
      { role: "assistant", content: nil, tool_calls: [{ "id" => "c1", "tool" => "read_file", "args" => {} }] },
      { role: "tool", tool_call_id: "c1", content: "result-1" },
      { role: "tool", tool_call_id: "c2", content: "result-2" },
      { role: "user", content: "<step_budget current=\"5\" alert=\"nearing limit\" />" }
    ]

    formatted = formatter.format_messages(messages)
    assert_equal 2, formatted.size, "tool results + following user must coalesce into ONE user message"

    content = formatted[1]["content"]
    assert_equal "user", formatted[1]["role"]
    assert_kind_of Array, content, "tool_result blocks must survive as an array"
    assert_equal "tool_result", content[0]["type"]
    assert_equal "c1", content[0]["tool_use_id"], "tool_result blocks must stay intact hashes"
    assert_equal "tool_result", content[1]["type"]
    last_block = content.last
    assert_equal "text", last_block["type"]
    assert_includes last_block["text"], "<step_budget"
  end

  def test_anthropic_consecutive_plain_users_are_merged
    formatter = Rubik::LLM::AnthropicFormatter.new
    messages = [
      { role: "user", content: "first" },
      { role: "user", content: "second" }
    ]
    formatted = formatter.format_messages(messages)
    assert_equal 1, formatted.size
    assert_equal "first\n\nsecond", formatted[0]["content"]
  end

  # Plan 61 B15/B4: /api/chat NDJSON lines carry message.content (+ optional
  # message.tool_calls) — both must surface as Chunk deltas.
  def test_ollama_formatter_parses_chat_shape_text_and_tool_calls
    formatter = Rubik::LLM::OllamaFormatter.new

    text_chunk = formatter.parse_stream_event(
      { type: "message", data: '{"model":"m","message":{"role":"assistant","content":"Hello"},"done":false}' }
    )
    assert_equal "Hello", text_chunk.text_delta
    refute text_chunk.done?

    tool_chunk = formatter.parse_stream_event(
      { type: "message",
        data: '{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"write_file","arguments":{"path":"a.rb"}}}]},"done":false}' }
    )
    delta = tool_chunk.tool_use_delta
    assert delta, "chat tool_calls must produce a tool_use_delta"
    assert_equal 1, delta.size
    assert_equal "write_file", delta[0]["name"]
    assert_equal({ "path" => "a.rb" }, delta[0]["args"])

    done_chunk = formatter.parse_stream_event(
      { type: "message", data: '{"model":"m","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":7,"eval_count":3}' }
    )
    assert done_chunk.done?
    assert_equal 7, done_chunk.usage[:input_tokens]
  end
end
