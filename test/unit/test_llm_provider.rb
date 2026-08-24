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

  def test_openai_compatible_with_wrapped_data_response
    mock_wrapped_response = {
      "success" => true,
      "data" => {
        "choices" => [
          { "message" => { "content" => "Wrapped answer", "role" => "assistant" } }
        ],
        "usage" => { "prompt_tokens" => 8, "completion_tokens" => 4 }
      }
    }

    Rubik::LLM::HTTPClient.stub :post_json, mock_wrapped_response do
      provider = Rubik::LLM::OpenAICompatibleProvider.new(
        endpoint: "https://api.cline.bot/api/v1/chat/completions",
        api_key: "sk-test",
        model: "cline-pass/deepseek-v4-flash"
      )
      res = provider.complete([{ role: "user", content: "hi" }])

      assert_equal "Wrapped answer", res.text
      assert_equal 8, res.usage[:input_tokens]
      assert_equal 4, res.usage[:output_tokens]
    end
  end

  def test_normalize_endpoint_automagical_expansion
    norm = ->(url) { Rubik::LLM::OpenAICompatibleProvider.normalize_endpoint(url) }

    assert_equal "https://api.deepseek.com/chat/completions", norm.call("https://api.deepseek.com")
    assert_equal "https://api.deepseek.com/chat/completions", norm.call("https://api.deepseek.com/")
    assert_equal "https://openrouter.ai/api/v1/chat/completions", norm.call("https://openrouter.ai/api/v1")
    assert_equal "https://openrouter.ai/api/v1/chat/completions", norm.call("https://openrouter.ai")
    assert_equal "https://api.openai.com/v1/chat/completions", norm.call("https://api.openai.com/v1")
    assert_equal "https://api.openai.com/v1/chat/completions", norm.call("https://api.openai.com")
    assert_equal "https://api.cline.bot/api/v1/chat/completions", norm.call("https://api.cline.bot")
    assert_equal "https://api.cline.bot/api/v1/chat/completions", norm.call("https://api.cline.bot/api/v1")
    assert_equal "https://api.groq.com/openai/v1/chat/completions", norm.call("https://api.groq.com/openai/v1")
    assert_equal "http://localhost:8000/v1/chat/completions", norm.call("http://localhost:8000")
    assert_equal "http://localhost:1234/v1/chat/completions", norm.call("http://localhost:1234/v1")
    # Already complete endpoints remain unchanged
    assert_equal "https://custom.ai/v1/chat/completions", norm.call("https://custom.ai/v1/chat/completions")
  end

  def test_anthropic_default_model_is_modern
    provider = Rubik::LLM::AnthropicProvider.new
    assert_equal "claude-3-5-sonnet-20241022", provider.model
  end
end
