# frozen_string_literal: true

require "test_helper"
require "rubik/orchestrator/loop"
require "rubik/repl/shell"
require "stringio"

class MockHistoryProvider
  attr_reader :received_histories

  def initialize(responses = ["Answer 1", "Answer 2"])
    @responses = responses
    @received_histories = []
  end

  def complete(history, _opts = {})
    @received_histories << history.dup
    resp = @responses.shift || "Default answer"
    MockResponse.new(resp)
  end

  class MockResponse
    attr_reader :text

    def initialize(text)
      @text = text
    end

    def tool_calls?
      false
    end

    def tool_calls
      []
    end

    def usage
      { input_tokens: 10, output_tokens: 10 }
    end
  end
end

class TestConversationHistory < Minitest::Test
  def setup
    @output = StringIO.new
  end

  def test_loop_includes_conversation_history
    provider = MockHistoryProvider.new(["Sure, continuing..."])
    tool_registry = Rubik::Tools::Registry.new
    loop_inst = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: tool_registry
    )

    prior_history = [
      { role: "user", content: "Step 1: Create file" },
      { role: "assistant", content: "I created the file." }
    ]

    res = loop_inst.run("Continue please", conversation_history: prior_history)
    assert res[:ok]
    assert_equal "Sure, continuing...", res[:output]

    received = provider.received_histories.first
    assert received, "Provider should have received a history"

    # Should contain: system, user (Step 1), assistant (I created...), user (Continue please)
    roles = received.map { |m| m[:role] }
    assert_equal ["system", "user", "assistant", "user"], roles

    assert_equal "Step 1: Create file", received[1][:content]
    assert_equal "I created the file.", received[2][:content]
    assert_includes received[3][:content], "Continue please"
  end

  def test_shell_accumulates_and_clears_conversation_history
    shell = Rubik::REPL::Shell.new(output: @output)
    provider = MockHistoryProvider.new([
                                         "First assistant response",
                                         "Second assistant response to continuation"
                                       ])

    # Stub router to return our mock provider
    shell.instance_variable_set(:@router, Object.new)
    shell.router.define_singleton_method(:route) do |**_args|
      { provider: provider, model: "test-model", spec: { "provider" => "mock", "name" => "test" }, role: "default", context_limit: 32_768 }
    end

    # Turn 1
    shell.execute_input("İlk görevi yap")
    assert_equal 2, shell.conversation_history.size
    assert_equal "İlk görevi yap", shell.conversation_history[0][:content]
    assert_equal "First assistant response", shell.conversation_history[1][:content]

    # Turn 2: continuation
    shell.execute_input("Devam et lütfen")
    assert_equal 4, shell.conversation_history.size
    assert_equal "Devam et lütfen", shell.conversation_history[2][:content]
    assert_equal "Second assistant response to continuation", shell.conversation_history[3][:content]

    # Check that in Turn 2, provider received Turn 1 context
    turn2_history = provider.received_histories[1]
    turn2_roles = turn2_history.map { |m| m[:role] }
    assert_equal ["system", "user", "assistant", "user"], turn2_roles
    assert_equal "İlk görevi yap", turn2_history[1][:content]
    assert_equal "First assistant response", turn2_history[2][:content]

    # Test !clear / !reset
    @output.reopen
    shell.execute_input("!clear")
    assert_empty shell.conversation_history
    assert_includes @output.string, "Conversation context cleared"
  end

  def test_repl_commands_captured_in_history
    shell = Rubik::REPL::Shell.new(output: @output)

    # Execute a diagnostic command: !status
    shell.execute_input("!status")
    assert_equal 2, shell.conversation_history.size
    assert_equal "status", shell.conversation_history[0][:content]
    assert_includes shell.conversation_history[1][:content], "Project:"
    assert_includes shell.conversation_history[1][:content], "Default Model:"
  end
end
