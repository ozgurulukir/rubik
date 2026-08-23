# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestREPL < Minitest::Test
  def setup
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(output: @output)
  end

  def test_help_command_lists_default_commands
    @shell.execute_input("!help")
    out = @output.string
    assert_includes out, "!help"
    assert_includes out, "!status"
    assert_includes out, "!quit"
  end

  def test_unknown_command_shows_error
    @shell.execute_input("!unknown_cmd")
    assert_includes @output.string, "Bilinmeyen komut: !unknown_cmd. !help'e bakın."
  end

  def test_hooks_execution_order_and_resilience
    hook_calls = []

    @shell.hooks.register(:before_command) { |cmd, _| hook_calls << "before_#{cmd}" }
    @shell.hooks.register(:before_command) { raise "Hook error!" }
    @shell.hooks.register(:after_command) { |cmd, _| hook_calls << "after_#{cmd}" }

    @shell.execute_input("!status")

    assert_equal ["before_status", "after_status"], hook_calls
  end

  def test_stream_input_execution
    stream = StringIO.new("!status\n!quit\n")
    @shell.run(stream)
    assert_includes @output.string, "Model:"
  end
end
