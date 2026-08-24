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
end
