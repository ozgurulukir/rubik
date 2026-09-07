# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"

class TestMcpManagerComposability < Minitest::Test
  def setup
    @ruby = RbConfig.ruby
    @mock_server_script = <<~RUBY
      require "json"
      $stdout.sync = true
      $stderr.sync = true
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
              "capabilities" => {},
              "serverInfo" => { "name" => "composable-mock", "version" => "1.0.0" }
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
                  "name" => "ping_tool",
                  "description" => "Test ping tool",
                  "inputSchema" => { "type" => "object" }
                }
              ]
            }
          })
        when "ping"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "result" => {} })
        end
      end
    RUBY

    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
    @config = Rubik::Config.new(root_dir: Dir.mktmpdir, home_dir: Dir.mktmpdir)

    @manager = Rubik::MCP::Manager.new(
      config: @config,
      tools_registry: @tools_registry,
      context: @root_context
    )
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
  end

  def test_enable_server_registers_tools_and_service
    @manager.add_server(
      "test_srv",
      { "command" => @ruby, "args" => ["-e", @mock_server_script] },
      auto_start: false
    )

    assert_equal :disabled, @manager.statuses["test_srv"]
    assert_nil @tools_registry.get("mcp_test_srv_ping_tool")

    @manager.enable_server("test_srv")

    assert_equal :active, @manager.statuses["test_srv"]
    refute_nil @tools_registry.get("mcp_test_srv_ping_tool")
    assert @root_context.has?("mcp:test_srv")
  end

  def test_disable_server_executes_lifo_inverses
    @manager.add_server(
      "test_srv",
      { "command" => @ruby, "args" => ["-e", @mock_server_script] },
      auto_start: true
    )

    client = @manager.client("test_srv")
    assert client&.running?
    assert @tools_registry.get("mcp_test_srv_ping_tool")

    @manager.disable_server("test_srv")

    assert_equal :disabled, @manager.statuses["test_srv"]
    assert_nil @tools_registry.get("mcp_test_srv_ping_tool")
    refute @root_context.has?("mcp:test_srv")
    assert_equal false, client.running?
    assert @manager.servers.key?("test_srv"), "Configuration should be preserved after disable"
  end

  def test_atomic_failure_rollback
    # Server with invalid command to simulate startup crash
    @manager.add_server(
      "failing_srv",
      { "command" => "non_existent_rubik_binary_xyz_123" },
      auto_start: false
    )

    assert_raises(Rubik::MCP::ConnectionError) do
      @manager.enable_server("failing_srv")
    end

    assert_equal :failed, @manager.statuses["failing_srv"]
    assert_nil @manager.client("failing_srv")
    refute @root_context.has?("mcp:failing_srv")
    assert_empty @tools_registry.list
  end

  def test_remove_server_stops_and_clears_configuration
    @manager.add_server(
      "ephemeral_srv",
      { "command" => @ruby, "args" => ["-e", @mock_server_script] },
      auto_start: true
    )

    assert @manager.servers.key?("ephemeral_srv")
    assert_equal :active, @manager.statuses["ephemeral_srv"]

    @manager.remove_server("ephemeral_srv")

    refute @manager.servers.key?("ephemeral_srv")
    assert_nil @manager.statuses["ephemeral_srv"]
    assert_nil @tools_registry.get("mcp_ephemeral_srv_ping_tool")
  end

  def test_connect_and_disconnect_ephemeral
    @manager.connect("session_srv", @ruby, ["-e", @mock_server_script])
    assert_equal :active, @manager.statuses["session_srv"]
    refute_nil @tools_registry.get("mcp_session_srv_ping_tool")

    @manager.disconnect("session_srv")
    assert_nil @manager.statuses["session_srv"]
    assert_nil @tools_registry.get("mcp_session_srv_ping_tool")
  end

  def test_stop_all_cleans_up_everything
    @manager.connect("srv1", @ruby, ["-e", @mock_server_script])
    @manager.connect("srv2", @ruby, ["-e", @mock_server_script])

    assert_equal 2, @tools_registry.list.size

    @manager.stop_all

    assert_equal :disabled, @manager.statuses["srv1"]
    assert_equal :disabled, @manager.statuses["srv2"]
    assert_empty @tools_registry.list
  end

  def test_security_guard_blocks_dangerous_mcp_command
    err = assert_raises(Rubik::MCP::ConnectionError) do
      @manager.add_server("evil_rm", { "command" => "rm", "args" => ["-rf", "/"] }, auto_start: true)
    end
    assert_match(/Security blocked MCP process/i, err.message)
    assert_equal :failed, @manager.statuses["evil_rm"]
    assert_empty @tools_registry.list
  end
end
