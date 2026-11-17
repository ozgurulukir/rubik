# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/connect/prompt_ui"

class TestConnectPromptUI < Minitest::Test
  # TTY-shaped spy: #mask exists (so PromptUI#secret routes to it like it
  # does on a real TTY::Prompt) and #select mirrors tty-prompt's own
  # 1-based default validation — a 0 default raises ConfigurationError,
  # exactly what the gem does on a real terminal.
  class TtySpy
    attr_reader :select_kwargs

    def initialize
      @select_kwargs = {}
    end

    def select(_question, choices, **kwargs)
      @select_kwargs = kwargs
      default = kwargs[:default]
      raise TTY::Prompt::ConfigurationError, "default index `#{default.inspect}` out of range" if !default.is_a?(Integer) || default < 1 || default > choices.size

      choices[default - 1]
    end

    def mask(_question, **_kwargs)
      "masked-secret"
    end

    def ask(question, **_kwargs)
      question.reverse
    end

    def yes?(_question, **_kwargs)
      true
    end
  end

  def test_select_default_is_one_based_for_real_tty_prompts
    spy = TtySpy.new
    ui = Rubik::Connect::PromptUI.new(input: StringIO.new, output: StringIO.new, prompt: spy)

    chosen = ui.select("Pick:", ["a", "b", "c"], default: "b")

    assert_equal "b", chosen
    assert_equal 2, spy.select_kwargs[:default], "tty-prompt defaults are 1-based"
  end

  def test_select_without_default_preselects_first
    spy = TtySpy.new
    ui = Rubik::Connect::PromptUI.new(input: StringIO.new, output: StringIO.new, prompt: spy)

    chosen = ui.select("Pick:", ["a", "b", "c"])

    assert_equal "a", chosen
    assert_equal 1, spy.select_kwargs[:default]
  end

  def test_secret_routes_to_mask_on_tty_shaped_targets
    spy = TtySpy.new
    ui = Rubik::Connect::PromptUI.new(input: StringIO.new, output: StringIO.new, prompt: spy)

    assert_equal "masked-secret", ui.secret("Key:")
  end

  def test_non_interactive_without_injected_prompt
    ui = Rubik::Connect::PromptUI.new(input: StringIO.new, output: StringIO.new)

    assert_equal :non_interactive, ui.select("Pick:", ["a"])
    assert_equal :non_interactive, ui.ask("Q:")
    assert_equal :non_interactive, ui.secret("K:")
    assert_equal :non_interactive, ui.yes?("Y?")
  end
end
