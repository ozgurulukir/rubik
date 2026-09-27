# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"

class TestReplMcpCommand < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_mcp_root")
    @temp_home = Dir.mktmpdir("rubik_mcp_home")
    @out = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out)

    @ruby = RbConfig.ruby
    # Plan 111 F1: database-less binaries are fail-closed at the command
    # gate; the MCP tests play the operator allowlisting the interpreter.
    @shell.guard.set_allowed_commands([@ruby])
    @mock_server_cmd = <<~RUBY
      require "json"
      $stdout.sync = true
      while (line = gets)
        line = line.strip
        next if line.empty?
        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        req_id = msg["id"]
        case msg["method"]
        when "initialize"
          puts JSON.dump({
            "jsonrpc" => "2.0",
            "id" => req_id,
            "result" => {
              "protocolVersion" => "2024-11-05",
              "serverInfo" => { "name" => "repl-mock", "version" => "1.0.0" }
            }
          })
        when "notifications/initialized"
          # noop
        when "tools/list"
          puts JSON.dump({
            "jsonrpc" => "2.0",
            "id" => req_id,
            "result" => {
              "tools" => [
                {
                  "name" => "greet",
                  "description" => "Greets the user",
                  "inputSchema" => {
                    "type" => "object",
                    "properties" => { "name" => { "type" => "string" } }
                  }
                }
              ]
            }
          })
        when "ping"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "result" => {} })
        end
      end
    RUBY
    @server_file = File.join(@temp_root, "mock_server.rb")
    File.write(@server_file, @mock_server_cmd)
  end

  def teardown
    @shell.stop
    begin
      FileUtils.remove_entry(@temp_root)
    rescue StandardError
      nil
    end
    begin
      FileUtils.remove_entry(@temp_home)
    rescue StandardError
      nil
    end
  end

  def test_mcp_status_empty
    @out.reopen
    @shell.execute_input("!mcp")
    assert_includes @out.string, "=== Model Context Protocol (MCP) Servers ==="
    assert_includes @out.string, "No MCP servers configured or active."
  end

  def test_mcp_connect_list_ping_disconnect
    @out.reopen
    @shell.execute_input("!mcp connect testmock #{@ruby} #{@server_file}")
    assert_includes @out.string, "MCP server 'testmock' connected [Session only] (1 tool(s) registered)."

    @out.reopen
    @shell.execute_input("!mcp status")
    assert_includes @out.string, "testmock [ACTIVE]"
    assert_includes @out.string, "1 registered"

    @out.reopen
    @shell.execute_input("!mcp list testmock")
    assert_includes @out.string, "=== Tools for MCP Server 'testmock' (1) ==="
    assert_includes @out.string, "mcp_testmock_greet"
    assert_includes @out.string, "Parameters: name"

    @out.reopen
    @shell.execute_input("!mcp ping testmock")
    assert_includes @out.string, "MCP server 'testmock' is alive"

    @out.reopen
    @shell.execute_input("!mcp disable testmock")
    assert_includes @out.string, "MCP server 'testmock' disabled and tools unregistered."

    @out.reopen
    @shell.execute_input("!mcp enable testmock")
    assert_includes @out.string, "MCP server 'testmock' enabled (1 tool(s) registered)."

    @out.reopen
    @shell.execute_input("!mcp disconnect testmock")
    assert_includes @out.string, "MCP server 'testmock' disconnected."

    @out.reopen
    @shell.execute_input("!mcp status")
    assert_includes @out.string, "No MCP servers configured or active."
  end

  def test_mcp_add_and_remove_with_scope
    @out.reopen
    @shell.execute_input("!mcp add persrv #{@ruby} #{@server_file} -p")
    assert_includes @out.string, "MCP server 'persrv' added and started (1 tool(s) registered) [Project level (.rubik/config.yml)]."

    @out.reopen
    @shell.execute_input("!mcp remove persrv -p")
    assert_includes @out.string, "MCP server 'persrv' removed [Project level (.rubik/config.yml)]."
  end

  def test_mcp_unknown_action
    @out.reopen
    @shell.execute_input("!mcp foobar")
    assert_includes @out.string, "Unknown !mcp action 'foobar'."
  end
end
