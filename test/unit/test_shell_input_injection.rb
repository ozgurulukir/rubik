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
    src = File.read("lib/rubik/repl/shell.rb")
    refute_match(/\$\s*stdin\s*\.\s*gets/, src,
                 "shell.rb must not call $stdin.gets directly; use @input.gets")
  end

  def test_shell_no_longer_calls_Reline_readline_directly
    # Should call @reline.readline or self.reline.readline, not Reline.readline.
    src = File.read("lib/rubik/repl/shell.rb")
    refute_match(/\bReline\s*\.\s*readline\b/, src,
                 "shell.rb must not call Reline.readline directly; use @reline.readline")
  end

  def test_shell_no_longer_uses_Reline_HISTORY_constant
    # Should use @reline::HISTORY (the constant on the injected module).
    src = File.read("lib/rubik/repl/shell.rb")
    refute_match(/\bReline\s*::\s*HISTORY\b/, src,
                 "shell.rb must not use Reline::HISTORY; use @reline::HISTORY")
  end

  def test_shell_uses_injected_input_for_prompt_yes_no
    src = File.read("lib/rubik/repl/shell.rb")
    # The yes/no prompt block should reference @input, not $stdin.
    assert_match(/@input\.gets/, src,
                 "shell.rb's prompt block should call @input.gets")
    # And the test should also use @input.tty? not $stdin.tty?
    assert_match(/@input\.tty\?/, src,
                 "shell.rb's tty? check should use @input.tty?")
  end

  def test_agent_command_uses_shell_input_when_available
    src = File.read("lib/rubik/repl/commands/agent.rb")
    assert_match(/shell\.input/, src,
                 "agent.rb should reference shell.input (with fallback to $stdin for compat)")
  end
end
