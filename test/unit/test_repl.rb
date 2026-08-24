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
    assert_includes @output.string, "Bilinmeyen komut: !unknown_cmd"
    assert_includes @output.string, "Kullanılabilir komutlar:"
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

  def test_inline_shift_operator_does_not_trigger_heredoc
    executed_inputs = []
    @shell.define_singleton_method(:execute_input) do |text|
      executed_inputs << text
    end

    # Mock Reline with inline << operator lines
    lines = ["arr << item", "x = a << 1", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end

    assert_includes executed_inputs, "arr << item"
    assert_includes executed_inputs, "x = a << 1"
  end

  def test_explicit_heredoc_multiline_block
    executed_inputs = []
    @shell.define_singleton_method(:execute_input) do |text|
      executed_inputs << text
    end

    lines = ["<<EOF", "line 1", "line 2", "EOF", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end

    assert_equal 1, executed_inputs.size
    assert_equal "line 1\nline 2", executed_inputs.first
  end

  def test_eof_or_ctrl_d_stops_interactive_loop
    lines = ["\x04"] # Ctrl+D ascii
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end

    refute @shell.running?
  end
end
