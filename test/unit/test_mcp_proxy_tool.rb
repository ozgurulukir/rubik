# frozen_string_literal: true

require_relative "../test_helper"

class TestMcpProxyTool < Minitest::Test
  class MockMcpClient
    attr_reader :calls

    def initialize
      @calls = []
      @should_fail = false
      @should_raise = false
    end

    attr_writer :should_fail, :should_raise

    def call_tool(name, args)
      @calls << { name: name, args: args }
      raise Rubik::MCP::ConnectionError, "Connection reset" if @should_raise

      if @should_fail
        Rubik::MCP::ToolResult.new(
          content: [{ "type" => "text", "text" => "Tool failed" }],
          is_error: true,
          text: "Tool failed"
        )
      else
        Rubik::MCP::ToolResult.new(
          content: [{ "type" => "text", "text" => "Calculated: #{args[:x].to_i + args[:y].to_i}" }],
          is_error: false,
          text: "Calculated: #{args[:x].to_i + args[:y].to_i}"
        )
      end
    end
  end

  def setup
    @mock_client = MockMcpClient.new
    @tool_def = {
      "name" => "add_numbers",
      "description" => "Adds two numbers together",
      "inputSchema" => {
        "type" => "object",
        "properties" => {
          "x" => { "type" => "number" },
          "y" => { "type" => "number" }
        },
        "required" => ["x", "y"]
      }
    }
    @proxy = Rubik::MCP::ProxyTool.new(
      server_name: "calculator-service",
      tool_def: @tool_def,
      client: @mock_client
    )
  end

  def test_inheritance_and_metadata
    assert_kind_of Rubik::Tools::BaseTool, @proxy
    assert_equal "mcp_calculator_service_add_numbers", @proxy.name
    assert_equal "[MCP: calculator-service] Adds two numbers together", @proxy.description
    assert_equal :execute, @proxy.risk
    assert_equal "object", @proxy.params_schema["type"]
    assert_equal ["x", "y"], @proxy.params_schema["required"]
  end

  def test_to_h_schema_structure
    schema = @proxy.to_h
    assert_equal "mcp_calculator_service_add_numbers", schema[:name]
    assert_equal "[MCP: calculator-service] Adds two numbers together", schema[:description]
    assert_equal :execute, schema[:risk]
    assert_equal "object", schema[:parameters]["type"]
  end

  def test_successful_execution
    res = @proxy.execute(x: 5, y: 7)
    assert_instance_of Rubik::Tools::Result, res
    assert_equal :ok, res.status
    assert_equal true, res.ok?
    assert_equal false, res.error?
    assert_equal "Calculated: 12", res.output
    assert_equal "Calculated: 12", res.to_s
    assert_equal 1, @mock_client.calls.size
    assert_equal "add_numbers", @mock_client.calls.first[:name]
  end

  def test_failure_tool_execution
    @mock_client.should_fail = true
    res = @proxy.execute(x: 1, y: 2)
    assert_instance_of Rubik::Tools::Result, res
    assert_equal :error, res.status
    assert_equal false, res.ok?
    assert_equal true, res.error?
    assert_equal "Tool failed", res.output
  end

  def test_client_exception_handling
    @mock_client.should_raise = true
    res = @proxy.execute(x: 1, y: 2)
    assert_instance_of Rubik::Tools::Result, res
    assert_equal :error, res.status
    assert_equal "Connection reset", res.output
    assert_equal "Connection reset", res.error
  end

  def test_risk_from_annotations_read_only_hint
    tool = Rubik::MCP::ProxyTool.new(
      server_name: "test",
      tool_def: { "name" => "search", "annotations" => { "readOnlyHint" => true } },
      client: @mock_client
    )
    assert_equal :read, tool.risk
  end

  def test_risk_from_annotations_destructive_hint
    tool = Rubik::MCP::ProxyTool.new(
      server_name: "test",
      tool_def: { "name" => "drop_table", "annotations" => { "destructiveHint" => true } },
      client: @mock_client
    )
    assert_equal :write, tool.risk
  end

  def test_risk_defaults_to_execute_without_annotations
    assert_equal :execute, @proxy.risk
  end

  def test_output_passes_through_untruncated_for_executor_level_truncation
    giant_text = "A" * 70_000
    mock = Object.new
    mock.define_singleton_method(:call_tool) do |_name, _args|
      Rubik::MCP::ToolResult.new(content: [{ "type" => "text", "text" => giant_text }], text: giant_text)
    end

    tool = Rubik::MCP::ProxyTool.new(server_name: "test", tool_def: { "name" => "big" }, client: mock)
    res = tool.execute({})
    assert_equal :ok, res.status
    # ProxyTool no longer pre-truncates: output bounding is the orchestrator
    # Truncator's single responsibility (head_tail strategy, config-driven).
    assert_equal 70_000, res.output.length
  end

  def test_schema_sanitization_when_malformed
    tool = Rubik::MCP::ProxyTool.new(
      server_name: "test",
      tool_def: { "name" => "malformed", "inputSchema" => "not-a-hash" },
      client: @mock_client
    )
    assert_equal "object", tool.params_schema["type"]
    assert_equal({}, tool.params_schema["properties"])
  end
end
