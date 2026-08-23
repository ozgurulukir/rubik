# frozen_string_literal: true

require_relative "../test_helper"

class TestLLMProvider < Minitest::Test
  def setup
    @registry = Rubik::LLM::Registry.new
  end

  def test_registry_list_and_get
    assert_includes @registry.list, "ollama"
    assert_includes @registry.list, "openai"
    assert_includes @registry.list, "anthropic"

    assert_kind_of Rubik::LLM::OllamaProvider, @registry.get("ollama")
  end

  def test_openai_missing_api_key_raises_error
    ENV.delete("OPENAI_API_KEY")
    provider = Rubik::LLM::OpenAIProvider.new

    assert_raises(Rubik::LLM::ClientError) do
      provider.complete([{ role: "user", content: "hello" }])
    end
  end

  def test_prompt_sanitization
    provider = Rubik::LLM::OllamaProvider.new
    sanitized = provider.sanitize_prompt("do something")
    assert_equal "<user_input>do something</user_input>", sanitized
  end

  def test_mock_ollama_completion
    mock_response = {
      "message" => { "content" => "Hello back!" },
      "prompt_eval_count" => 10,
      "eval_count" => 5
    }

    Rubik::LLM::HTTPClient.stub :post_json, mock_response do
      provider = Rubik::LLM::OllamaProvider.new
      res = provider.complete([{ role: "user", content: "hi" }])

      assert_equal "Hello back!", res.text
      assert_equal 10, res.usage[:input_tokens]
      assert_equal 5, res.usage[:output_tokens]
    end
  end
end
