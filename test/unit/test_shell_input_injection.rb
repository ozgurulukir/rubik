# frozen_string_literal: true

require_relative "../test_helper"

# Tests for PR-I: Shell constructor accepts `input:` and `reline:`
# kwargs; direct `$stdin.gets` and `Reline.readline` calls removed
# from the hot paths.
class TestShellInputInjection < Minitest::Test
  def test_shell_initialize_signature_accepts_input_kwarg
    src = File.read("lib/rubik/repl/shell.rb")
    # The constructor must declare `input: $stdin` so callers can
    # inject a StringIO or other IO without monkey-patching $stdin.
    assert_match(/def initialize\([^)]*input:\s*\$stdin/, src,
                 "Shell#initialize must accept input: kwarg with $stdin default")
  end

  def test_shell_initialize_signature_accepts_reline_kwarg
    src = File.read("lib/rubik/repl/shell.rb")
    assert_match(/def initialize\([^)]*reline:\s*Reline/, src,
                 "Shell#initialize must accept reline: kwarg with Reline default")
  end

  def test_shell_stores_input_and_reline_instance_vars
    src = File.read("lib/rubik/repl/shell.rb")
    assert_match(/@input\s*=\s*input/, src,
                 "Shell must store @input = input")
    assert_match(/@reline\s*=\s*reline/, src,
                 "Shell must store @reline = reline")
  end

  def test_shell_no_longer_calls_dollar_stdin_gets
    # Öneri 3 Kademe 1: guard, InputLoop çıkarımı sonrası hem shell.rb hem
    # input_loop.rb'yi kapsar (girdi döngüsü mixin'e taşındı).
    [shell_src, input_loop_src].each do |src|
      refute_match(/\$\s*stdin\s*\.\s*gets/, src,
                   "input hot path must not call $stdin.gets directly; use @input.gets")
    end
  end

  def test_shell_no_longer_calls_Reline_readline_directly # rubocop:disable Naming/MethodName -- Reline özel ad
    # Should call @reline.readline or self.reline.readline, not Reline.readline.
    [shell_src, input_loop_src].each do |src|
      refute_match(/\bReline\s*\.\s*readline\b/, src,
                   "input hot path must not call Reline.readline directly; use @reline.readline")
    end
  end

  def test_shell_no_longer_uses_Reline_HISTORY_constant # rubocop:disable Naming/MethodName -- Reline özel ad
    # Should use @reline::HISTORY (the constant on the injected module).
    [shell_src, input_loop_src].each do |src|
      refute_match(/\bReline\s*::\s*HISTORY\b/, src,
                   "input hot path must not use Reline::HISTORY; use @reline::HISTORY")
    end
  end

  def test_shell_uses_injected_reline_and_input_for_prompt_yes_no
    src = File.read("lib/rubik/repl/confirmations.rb")
    # The yes/no prompt routes through the injected @reline (not raw gets),
    # and interactivity detection uses the injected @input.
    assert_match(/@reline\.readline/, src,
                 "confirmations.rb's ask_yes_no should call @reline.readline")
    assert_match(/@input \|\| \$stdin/, src,
                 "confirmations.rb's interactive_input? should prefer @input")
  end

  def test_agent_command_uses_shell_ask_yes_no
    agent_files = Dir.glob("lib/rubik/repl/commands/agent*.rb")
    src = agent_files.map { |f| File.read(f) }.join("\n")
    # The plan approval goes through Shell#ask_yes_no, which reads via the
    # shell's injected input/reline instead of a raw $stdin.gets fallback.
    assert_match(/shell\.ask_yes_no/, src,
                 "agent commands should call shell.ask_yes_no for interactive confirmations")
    refute_match(/\$stdin\s*\.\s*gets/, src,
                 "agent commands must not call $stdin.gets directly")
  end

  private

  def shell_src
    File.read("lib/rubik/repl/shell.rb")
  end

  def input_loop_src
    File.read("lib/rubik/repl/input_loop.rb")
  end
end
