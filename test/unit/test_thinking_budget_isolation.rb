# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/llm/anthropic"
require_relative "../../lib/rubik/llm/openai_compatible"

class TestThinkingBudgetIsolation < Minitest::Test
  def setup
    @anthropic = Rubik::LLM::AnthropicProvider.new(model: "claude-3-7-sonnet-20250219")
    @openai_comp = Rubik::LLM::OpenAICompatibleProvider.new(model: "gpt-4o")
  end

  def test_anthropic_thinking_budget_calculation_and_temperature_rule
    # claude-3-7-sonnet with max_tokens 8192 and temperature 0.0
    payload = @anthropic.send(
      :build_payload,
      "claude-3-7-sonnet-20250219",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 8192, temperature: 0.0 }
    )

    # Thinking is enabled with 50% budget: 4096
    assert_equal({ type: "enabled", budget_tokens: 4096 }, payload[:thinking])
    # Temperature MUST be 1.0 (never 0.0) when thinking is active
    assert_equal 1.0, payload[:temperature]
  end

  def test_anthropic_thinking_budget_clamped_correctly
    # Very high ratio (0.9) on max_tokens 4096:
    # (4096 * 0.9).to_i = 3686, but must be clamped to max_tokens - 1024 = 3072
    payload = @anthropic.send(
      :build_payload,
      "claude-3-7-sonnet-20250219",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 4096, thinking_budget_ratio: 0.9 }
    )

    assert_equal({ type: "enabled", budget_tokens: 3072 }, payload[:thinking])
  end

  def test_anthropic_thinking_disabled_when_explicitly_flagged
    payload = @anthropic.send(
      :build_payload,
      "claude-3-7-sonnet-20250219",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 8192, temperature: 0.2, thinking: false }
    )

    assert_nil payload[:thinking]
    assert_equal 0.2, payload[:temperature]
  end

  def test_anthropic_adaptive_models_use_the_adaptive_thinking_form
    # 4.6+ / 5.x models reject the legacy budget_tokens form with a 400;
    # the payload must switch to the adaptive form with an effort level.
    payload = @anthropic.send(
      :build_payload,
      "claude-sonnet-5-5",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 16_384, temperature: 0.0 }
    )

    assert_equal({ type: "adaptive" }, payload[:thinking])
    assert_equal({ effort: "high" }, payload[:output_config])
    assert_equal 1.0, payload[:temperature]
  end

  def test_anthropic_forced_thinking_on_adaptive_model_skips_legacy_form
    # thinking: true on a modern model must NOT emit budget_tokens —
    # that form is a hard 400 there.
    payload = @anthropic.send(
      :build_payload,
      "claude-opus-5",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 16_384, thinking: true }
    )

    assert_equal({ type: "adaptive" }, payload[:thinking])
  end

  def test_anthropic_pre_thinking_models_get_no_thinking_attached
    # 3.5-and-earlier lines reject any thinking form; nothing may be attached.
    payload = @anthropic.send(
      :build_payload,
      "claude-3-5-sonnet-20241022",
      [{ "role" => "user", "content" => "hi" }],
      "",
      { max_tokens: 8192 }
    )

    assert_nil payload[:thinking]
    assert_nil payload[:output_config]
  end

  def test_anthropic_thinking_mode_classification
    assert_equal :legacy, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-3-7-sonnet-20250219")
    assert_equal :legacy, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-4-5")
    assert_equal :legacy, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-4-5-20250929")
    assert_equal :legacy, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-4-20250514")
    assert_equal :legacy, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-opus-4-1-20250805")
    assert_equal :adaptive, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-4-6")
    assert_equal :adaptive, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-5-5")
    assert_equal :adaptive, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-opus-5")
    assert_equal :adaptive, Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-fable-5-1")
    assert_nil Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-3-5-sonnet-20241022")
    assert_nil Rubik::LLM::AnthropicProvider.thinking_mode_for("claude-sonnet-latest")
  end

  def test_openai_reasoning_models_use_max_completion_tokens
    payload = @openai_comp.send(
      :build_payload,
      "o1-mini",
      [{ "role" => "user", "content" => "solve math" }],
      { max_tokens: 16_384, temperature: 0.7, reasoning_effort: "high" }
    )

    # Must map max_tokens -> max_completion_tokens
    assert_equal 16_384, payload[:max_completion_tokens]
    assert_nil payload[:max_tokens]
    # Temperature must be completely omitted for o1/o3 reasoning models
    assert_nil payload[:temperature]
    assert_equal "high", payload[:reasoning_effort]
  end

  def test_openai_o3_mini_detection
    payload = @openai_comp.send(
      :build_payload,
      "o3-mini",
      [{ "role" => "user", "content" => "solve code" }],
      { max_tokens: 8192, temperature: 0.0 }
    )

    assert_equal 8192, payload[:max_completion_tokens]
    assert_nil payload[:max_tokens]
    assert_nil payload[:temperature]
  end

  def test_openai_standard_models_keep_max_tokens_and_temperature
    payload = @openai_comp.send(
      :build_payload,
      "gpt-4o",
      [{ "role" => "user", "content" => "hello" }],
      { max_tokens: 4096, temperature: 0.5 }
    )

    assert_equal 4096, payload[:max_tokens]
    assert_nil payload[:max_completion_tokens]
    assert_equal 0.5, payload[:temperature]
  end
end
