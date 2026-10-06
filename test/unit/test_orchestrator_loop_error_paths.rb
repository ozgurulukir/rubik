# frozen_string_literal: true

require_relative "../test_helper"

# G13 remainder: Orchestrator::Loop's defensive-config and tool-call parse
# arms — a hostile config object must degrade to the default, and malformed
# model JSON must parse to nil instead of raising into the step loop.
class TestOrchestratorLoopErrorPaths < Minitest::Test
  class FetchBoomConfig
    def fetch(*) = raise KeyError, "config exploded"
  end

  class NilFetchConfig
    def fetch(*) = nil
  end

  def setup
    @loop = Rubik::Orchestrator::Loop.new(
      provider: Object.new,
      tool_registry: Rubik::Tools::Registry.new,
      max_steps: 5
    )
  end

  def test_safe_config_returns_default_when_fetch_raises
    @loop.instance_variable_set(:@config, FetchBoomConfig.new)

    assert_equal 7, @loop.send(:safe_config, "agent.x", 7)
  end

  def test_safe_config_returns_default_when_fetch_is_nil
    @loop.instance_variable_set(:@config, NilFetchConfig.new)

    assert_equal "dflt", @loop.send(:safe_config, "agent.x", "dflt")
  end

  def test_parse_tool_call_malformed_json_returns_nil
    # Input must both start with "{" and end with "}" to reach JSON.parse at
    # all; otherwise the ternary returns nil before the parser runs.
    assert_nil Rubik::Orchestrator::TurnExecutor.parse_tool_call("{oops}")
    assert_nil Rubik::Orchestrator::TurnExecutor.parse_tool_call("plain assistant prose")
  end

  def test_parse_tool_call_valid_json_parses
    parsed = Rubik::Orchestrator::TurnExecutor.parse_tool_call('{"tool": "read_file"}')

    assert_equal({ "tool" => "read_file" }, parsed)
  end
end
