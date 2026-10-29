# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "tempfile"

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

    # Issue #54: long multiline `ruby -e` children went silently
    # unresponsive on Windows — spawn the mock from a file instead (same
    # rationale as test_mcp_client.rb).
    @mock_server_file = Tempfile.create(["rubik_mock_mcp", ".rb"])
    @mock_server_file.write(@mock_server_script)
    @mock_server_file.close

    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
    @config = Rubik::Config.new(root_dir: Dir.mktmpdir, home_dir: Dir.mktmpdir)

    # Plan 111 F1: database-less binaries fail closed at the command gate;
    # these tests play the operator allowlisting the test interpreter
    # (same fixture pattern as test_repl_mcp_command.rb).
    @guard = Rubik::Security::Guard.new
    @guard.allowed_commands = [@ruby]

    @manager = Rubik::MCP::Manager.new(
      config: @config,
      tools_registry: @tools_registry,
      context: @root_context,
      guard: @guard
    )
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
    File.delete(@mock_server_file.path) if @mock_server_file && File.exist?(@mock_server_file.path)
  end

  def test_enable_server_registers_tools_and_service
    @manager.add_server(
      "test_srv",
      { "command" => @ruby, "args" => [@mock_server_file.path] },
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
      { "command" => @ruby, "args" => [@mock_server_file.path] },
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
      { "command" => @ruby, "args" => [@mock_server_file.path] },
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
    @manager.connect("session_srv", @ruby, [@mock_server_file.path])
    assert_equal :active, @manager.statuses["session_srv"]
    refute_nil @tools_registry.get("mcp_session_srv_ping_tool")

    @manager.disconnect("session_srv")
    assert_nil @manager.statuses["session_srv"]
    assert_nil @tools_registry.get("mcp_session_srv_ping_tool")
  end

  def test_reconnect_cycles_return_context_to_baseline
    @manager.add_server(
      "cycle_srv",
      { "command" => @ruby, "args" => [@mock_server_file.path] },
      auto_start: false
    )

    10.times do
      @manager.enable_server("cycle_srv")
      assert_equal :active, @manager.statuses["cycle_srv"]
      assert @root_context.has?("mcp:cycle_srv")
      @manager.disable_server("cycle_srv")
      assert_equal :disabled, @manager.statuses["cycle_srv"]
    end

    assert_equal 0, @root_context.disposable_count,
                 "reconnect cycles must not accumulate dead children, cascade inverses or service inverses"
    refute @root_context.has?("mcp:cycle_srv")
    assert_empty @tools_registry.list
  end

  def test_stop_all_cleans_up_everything
    @manager.connect("srv1", @ruby, [@mock_server_file.path])
    @manager.connect("srv2", @ruby, [@mock_server_file.path])

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

  # G13: one broken server definition must not block the others — the
  # load loop isolates the failure per server and keeps loading the rest.
  def test_broken_server_config_does_not_block_other_servers
    mgr = Class.new(Rubik::MCP::Manager) do
      def add_server(name, defn, auto_start: true, persist: nil)
        raise StandardError, "broken definition" if name == "broken"

        super
      end
    end
    manager = mgr.new(config: @config, tools_registry: @tools_registry, context: @root_context, guard: @guard)

    cfg = { "mcp.servers" => {
      "broken" => { "command" => @ruby, "args" => ["-e", "sleep 30"] },
      "healthy" => { "command" => @ruby, "args" => ["-e", "sleep 30"], "enabled" => false }
    } }
    _, err = capture_io do
      manager.load_from_config(cfg)
    end

    refute manager.statuses.key?("broken"), "the broken server must be skipped, not half-registered"
    assert manager.statuses.key?("healthy"), "the healthy server must still load"
    assert_match(/failed to load MCP server 'broken'/, err)
  ensure
    manager&.stop_all
  end

  # G13 remainder: a disable_server failure during stop_all is swallowed per
  # server — one wedged teardown must not strand the other servers running.
  def test_stop_all_survives_disable_failure
    tmp = Dir.mktmpdir("rubik_mcp_stopall")
    klass = Class.new(Rubik::MCP::Manager) do
      def disable_server(name)
        raise IOError, "stop boom" if name == "broken"

        super
      end
    end
    mgr = klass.new(tools_registry: Rubik::Tools::Registry.new, root_dir: tmp)
    mgr.instance_variable_get(:@servers)["broken"] = Object.new

    capture_io { mgr.stop_all }

    assert mgr.statuses.empty? || mgr.statuses["broken"].nil?,
           "stop_all must complete despite a raising disable"
  ensure
    FileUtils.remove_entry(tmp) if tmp && File.directory?(tmp)
  end

  def test_enable_server_does_not_hold_monitor_during_handshake
    parked = Queue.new
    resume = Queue.new

    latched_client = Object.new
    latched_client.define_singleton_method(:stop) {}
    latched_client.define_singleton_method(:running?) { true }

    manager = Rubik::MCP::Manager.new(tools_registry: @tools_registry)
    manager.instance_variable_get(:@servers)["parked_server"] = { "command" => "ruby" }

    connect_stub = lambda do |_name, _defn|
      parked << true
      resume.pop
      { client: latched_client, tools: [] }
    end

    thread = Thread.new do
      manager.stub(:connect_server, connect_stub) do
        manager.enable_server("parked_server")
      end
    end

    parked.pop

    status_read = nil
    status_thread = Thread.new do
      status_read = manager.statuses["parked_server"]
    end
    assert status_thread.join(1.0), "statuses read must not block while enable_server handshakes"
    assert_equal :connecting, status_read

    resume << true
    thread.join(2.0)
    assert_equal :active, manager.statuses["parked_server"]
  ensure
    begin
      resume << true
    rescue ThreadError
      nil
    end
    thread&.join(1.0)
  end
end
