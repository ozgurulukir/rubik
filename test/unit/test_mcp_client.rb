# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"

class TestMcpClient < Minitest::Test
  def setup
    @ruby = RbConfig.ruby
    # Plan 111 F1: database-less binaries fail closed at the command gate;
    # these tests play the operator allowlisting the test interpreter
    # (same fixture pattern as test_repl_mcp_command.rb).
    @guard = Rubik::Security::Guard.new
    @guard.allowed_commands = [@ruby]
    # Simple inline mock MCP server script
    @mock_server_code = <<~RUBY
      require "json"
      $stdout.sync = true
      $stderr.sync = true
      puts "[mock-mcp-log] Server starting..." # non-JSON line to test log tolerance
      while (line = gets)
        line = line.strip
        next if line.empty?
        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        req_id = msg["id"]
        method = msg["method"]

        case method
        when "initialize"
          res = {
            "jsonrpc" => "2.0",
            "id" => req_id,
            "result" => {
              "protocolVersion" => "2024-11-05",
              "capabilities" => { "tools" => {} },
              "serverInfo" => { "name" => "mock-mcp", "version" => "0.1.0" }
            }
          }
          puts JSON.dump(res)
        when "notifications/initialized"
          # no response for notifications
        when "tools/list"
          res = {
            "jsonrpc" => "2.0",
            "id" => req_id,
            "result" => {
              "tools" => [
                {
                  "name" => "echo",
                  "description" => "Echoes back input",
                  "inputSchema" => {
                    "type" => "object",
                    "properties" => { "message" => { "type" => "string" } },
                    "required" => ["message"]
                  }
                },
                {
                  "name" => "failing_tool",
                  "description" => "Fails intentionally",
                  "inputSchema" => { "type" => "object" }
                }
              ]
            }
          }
          puts JSON.dump(res)
        when "tools/call"
          t_name = msg.dig("params", "name")
          t_args = msg.dig("params", "arguments") || {}
          if t_name == "failing_tool"
            res = {
              "jsonrpc" => "2.0",
              "id" => req_id,
              "result" => {
                "content" => [{ "type" => "text", "text" => "Intentional failure occurred" }],
                "isError" => true
              }
            }
          else
            msg_text = t_args["message"] || "default"
            res = {
              "jsonrpc" => "2.0",
              "id" => req_id,
              "result" => {
                "content" => [{ "type" => "text", "text" => "Echo: \#{msg_text}" }],
                "isError" => false
              }
            }
          end
          puts JSON.dump(res)
        when "ping"
          res = { "jsonrpc" => "2.0", "id" => req_id, "result" => {} }
          puts JSON.dump(res)
        end
      end
    RUBY

    @client = Rubik::MCP::Client.new(
      @ruby,
      args: ["-e", @mock_server_code],
      name: "test-mock",
      guard: @guard
    )
  end

  def teardown
    @client&.stop
  end

  def test_start_and_handshake
    assert_equal false, @client.running?
    @client.start!
    assert_equal true, @client.running?
    assert_equal true, @client.initialized
    assert_equal "2024-11-05", @client.protocol_version
    assert_equal "mock-mcp", @client.server_info["name"]
    assert_equal "0.1.0", @client.server_info["version"]
  end

  def test_list_tools
    @client.start!
    tools = @client.list_tools
    assert_equal 2, tools.size
    names = tools.map { |t| t["name"] }
    assert_includes names, "echo"
    assert_includes names, "failing_tool"
  end

  def test_call_tool_success
    @client.start!
    res = @client.call_tool("echo", { "message" => "Rubik MCP rocks" })
    assert_instance_of Rubik::MCP::ToolResult, res
    assert_equal false, res.error?
    assert_equal "Echo: Rubik MCP rocks", res.to_s
    assert_equal "Echo: Rubik MCP rocks", res["text"]
  end

  def test_call_tool_failure_flag
    @client.start!
    res = @client.call_tool("failing_tool", {})
    assert_equal true, res.error?
    assert_equal "Intentional failure occurred", res.to_s
  end

  def test_ping
    @client.start!
    latency = @client.ping
    assert_operator latency, :>=, 0.0
  end

  def test_stop_cleans_up_process
    @client.start!
    pid = @client.transport.pid
    assert pid
    @client.stop
    assert_equal false, @client.running?
    # Give OS a moment to verify process termination
    sleep 0.1
    alive = begin
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
    assert_equal false, alive, "Process #{pid} should be terminated after stop"
  end
end
