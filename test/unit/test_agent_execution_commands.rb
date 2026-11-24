# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/repl/commands/agent_execution"

# Direct coverage for the agent-execution command spine: which commands
# exist, the synopses they advertise, and the !goal argument grammar.
# Before this file the module had no directly-named test; registration
# drift (a command silently dropping out of the spine, a synopsis drifting
# from the parser) was only observable end-to-end through a wired Shell.
class TestAgentExecutionCommands < Minitest::Test
  # Records register_command calls without wiring a real Shell: the module
  # under test only needs the registration surface, not dispatch, history,
  # or IO.
  class RecordingShell
    attr_reader :commands

    def initialize
      @commands = {}
    end

    def register_command(name, description:, usage: nil, custom: false, audience: nil, &handler)
      key = name.to_s.downcase.delete_prefix("!")
      @commands[key] = {
        description: description,
        usage: usage,
        custom: custom,
        audience: audience,
        handler: handler
      }
      true
    end
  end

  def setup
    @shell = RecordingShell.new
    Rubik::REPL::Commands::AgentExecution.register(@shell)
  end

  def test_registers_all_seven_agent_execution_commands
    expected = ["format", "goal", "lint", "plan", "sandbox", "sh", "test"]
    assert_equal expected, @shell.commands.keys.sort
  end

  def test_registered_synopses_match_the_shared_usage_constants
    assert_equal(
      Rubik::REPL::Commands::AgentExecution::USAGE_PLAN,
      @shell.commands["plan"][:usage]
    )
    assert_equal(
      Rubik::REPL::Commands::AgentExecution::USAGE_GOAL,
      @shell.commands["goal"][:usage]
    )
  end

  def test_lint_and_format_reach_agent_audience
    assert_equal(:both, @shell.commands["lint"][:audience])
    assert_equal(:both, @shell.commands["format"][:audience])
  end

  def test_interactive_commands_stay_human_audience
    ["plan", "goal", "sh", "test", "sandbox"].each do |name|
      assert_nil(
        @shell.commands[name][:audience],
        "expected #{name} to register without an explicit audience"
      )
    end
  end

  def test_goal_arg_grammar_accepts_space_form_steps
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["--steps", "200", "ship", "it"])
    expected = { custom_steps: 200, goal_text: "ship it", valid: true }
    assert_equal(expected, parsed)
  end

  def test_goal_arg_grammar_accepts_equals_form_steps
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["--steps=50", "fix", "the", "build"])
    expected = { custom_steps: 50, goal_text: "fix the build", valid: true }
    assert_equal(expected, parsed)
  end

  def test_goal_arg_grammar_rejects_non_numeric_steps
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["--steps=abc"])
    expected = { custom_steps: nil, goal_text: "", valid: false }
    assert_equal(expected, parsed)
  end

  def test_goal_arg_grammar_rejects_valueless_steps_flag
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["--steps"])
    expected = { custom_steps: nil, goal_text: "", valid: false }
    assert_equal(expected, parsed)
  end

  def test_goal_arg_grammar_rejects_zero_steps
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["--steps", "0", "x"])
    expected = { custom_steps: 0, goal_text: "x", valid: false }
    assert_equal(expected, parsed)
  end

  def test_multi_word_goal_starting_with_resume_stays_goal_text
    # Tek-argüman şartı: a multi-word goal whose first token is "resume"
    # is still goal text, not the resume subcommand.
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["resume", "the", "deployment"])
    expected = { custom_steps: nil, goal_text: "resume the deployment", valid: true }
    assert_equal(expected, parsed)
  end

  def test_plain_goal_text_round_trips
    parsed = Rubik::REPL::Commands::AgentExecution.send(:parse_goal_args, ["do", "the", "thing"])
    expected = { custom_steps: nil, goal_text: "do the thing", valid: true }
    assert_equal(expected, parsed)
  end
end
