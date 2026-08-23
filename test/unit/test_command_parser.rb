# frozen_string_literal: true

require_relative "../test_helper"

class TestCommandParser < Minitest::Test
  def test_parse_empty_input
    parsed = Rubik::REPL::CommandParser.parse("")
    assert_equal :empty, parsed.type
  end

  def test_parse_free_text_prompt
    parsed = Rubik::REPL::CommandParser.parse("Hello Rubik, fix this bug")
    assert_equal :prompt, parsed.type
    assert_equal "Hello Rubik, fix this bug", parsed.raw
  end

  def test_parse_bang_command
    parsed = Rubik::REPL::CommandParser.parse("!help status")
    assert_equal :command, parsed.type
    assert_equal "help", parsed.command_name
    assert_equal ["status"], parsed.args
  end

  def test_parse_quoted_arguments
    parsed = Rubik::REPL::CommandParser.parse('!context add "./my dir/path" "second file.txt"')
    assert_equal :command, parsed.type
    assert_equal "context", parsed.command_name
    assert_equal ["add", "./my dir/path", "second file.txt"], parsed.args
  end
end
