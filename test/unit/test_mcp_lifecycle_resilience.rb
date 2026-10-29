# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "tempfile"

# Issue #151: MCP lifecycle resilience contracts:
# 1. Server crash releases pipes/FDs and returns context & registry to baseline.
# 2. In-flight call during reload aborts cleanly without deadlock or hanging.
# 3. Server descendant process tree is cleanly terminated on disable.
class TestMcpLifecycleResilience < Minitest::Test
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
              "serverInfo" => { "name" => "resilience-mock", "version" => "1.0.0" }
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
                  "name" => "slow_echo",
                  "description" => "Slow echo tool",
                  "inputSchema" => { "type" => "object" }
                }
              ]
            }
          })
        when "tools/call"
          # Check if requested to sleep
          args = msg.dig("params", "arguments") || {}
          sleep(args["sleep"].to_f) if args["sleep"]
          puts JSON.dump({
            "jsonrpc" => "2.0",
            "id" => req_id,
            "result" => { "content" => [{ "type" => "text", "text" => "done" }] }
          })
        end
      end
    RUBY

    @mock_server_file = Tempfile.create(["rubik_resilience_mcp", ".rb"])
    @mock_server_file.write(@mock_server_script)
    @mock_server_file.close

    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
    @config = Rubik::Config.new(root_dir: Dir.mktmpdir, home_dir: Dir.mktmpdir)

    @guard = Rubik::Security::Guard.new
    @guard.allowed_commands = [@ruby, "bash"]

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

  def wait_for(timeout = 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    true
  end

  def test_server_crash_releases_pipes_and_returns_context_to_baseline
    @manager.add_server(
      "crash_srv",
      { "command" => @ruby, "args" => [@mock_server_file.path] },
      auto_start: true
    )

    client = @manager.client("crash_srv")
    assert client&.running?
    assert @tools_registry.get("mcp_crash_srv_slow_echo")

    transport = client.transport
    pid = transport.pid

    # Crash the server process from outside
    Process.kill("KILL", pid)
    sleep 0.15 # Allow reader thread to detect EOF

    refute client.running?

    # Now disable the crashed server
    @manager.disable_server("crash_srv")

    # Pipes must be closed (no open FD leak)
    assert transport.instance_variable_get(:@stdin)&.closed?
    assert transport.instance_variable_get(:@stdout)&.closed?
    assert transport.instance_variable_get(:@stderr)&.closed?

    # Context and registry must return to baseline
    refute @root_context.has?("mcp:crash_srv")
    assert_equal 0, @root_context.disposable_count
    assert_nil @tools_registry.get("mcp_crash_srv_slow_echo")
  end

  def test_in_flight_call_during_reload_aborts_cleanly
    @manager.add_server(
      "inflight_srv",
      { "command" => @ruby, "args" => [@mock_server_file.path] },
      auto_start: true
    )

    client = @manager.client("inflight_srv")
    assert client&.running?

    call_error = nil
    call_finished = false
    thr = Thread.new do
      client.call_tool("slow_echo", { "sleep" => 3.0 }, timeout: 5)
    rescue StandardError => e
      call_error = e
    ensure
      call_finished = true
    end

    # Give the thread a moment to send the request and enter wait_for_response
    sleep 0.2

    # Disable/reload while tool call is in-flight
    @manager.disable_server("inflight_srv")

    # In-flight thread must wake up and abort without deadlock
    thr.join(2.0)
    assert call_finished, "in-flight tool call must not hang on server disable"
    assert_kind_of Rubik::MCP::ConnectionError, call_error

    # Context and registry must return to baseline
    refute @root_context.has?("mcp:inflight_srv")
    assert_equal 0, @root_context.disposable_count
    assert_nil @tools_registry.get("mcp_inflight_srv_slow_echo")
  end

  def test_server_descendants_cleaned_up_on_disable
    return if Rubik::Platform.windows?

    descendant_script = <<~RUBY
      require "json"
      $stdout.sync = true
      # Spawn a background descendant worker
      descendant = spawn("sleep 60")
      while (line = gets)
        msg = JSON.parse(line.strip) rescue next
        if msg["method"] == "initialize"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "protocolVersion" => "2024-11-05" } })
        elsif msg["method"] == "tools/list"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "tools" => [] } })
        end
      end
    RUBY

    script_file = Tempfile.create(["rubik_descendant_mcp", ".rb"])
    script_file.write(descendant_script)
    script_file.close

    @manager.add_server(
      "tree_srv",
      { "command" => @ruby, "args" => [script_file.path] },
      auto_start: true
    )

    client = @manager.client("tree_srv")
    assert client&.running?
    parent_pid = client.transport.pid
    sleep 0.2

    children = Rubik::Platform.descendant_pids(parent_pid)

    @manager.disable_server("tree_srv")
    sleep 0.2

    # Verify both parent and descendant children are dead
    refute system("kill -0 #{parent_pid} 2>/dev/null"), "parent server process must be terminated"
    children.each do |cpid|
      alive = system("kill -0 #{cpid} 2>/dev/null")
      if alive
        begin
          Process.kill("KILL", cpid)
        rescue StandardError
          nil
        end
      end
      refute alive, "descendant process #{cpid} must be terminated"
    end
  ensure
    File.delete(script_file.path) if script_file && File.exist?(script_file.path)
  end

  # The child floods stderr BEFORE ever reading stdin. Without a stderr
  # drainer it blocks inside its write once the OS pipe buffer fills and
  # can never answer the handshake — every call times out with no hint
  # why (the classic popen3 deadlock).
  def test_chatty_stderr_does_not_deadlock_the_server
    chatty_script = <<~RUBY
      require "json"
      $stdout.sync = true
      $stderr.sync = true
      4000.times { |i| $stderr.puts("chatty \#{i} #{'x' * 60}") }
      while (line = gets)
        msg = JSON.parse(line.strip) rescue next
        case msg["method"]
        when "initialize"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "protocolVersion" => "2024-11-05" } })
        when "tools/list"
          puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "tools" => [] } })
        end
      end
    RUBY

    script_file = Tempfile.create(["rubik_chatty_stderr_mcp", ".rb"])
    script_file.write(chatty_script)
    script_file.close

    @manager.add_server(
      "chatty_srv",
      { "command" => @ruby, "args" => [script_file.path] },
      auto_start: true
    )

    client = @manager.client("chatty_srv")
    assert client&.running?, "handshake must complete while the child floods stderr"

    assert wait_for(2.0) { client.transport.stderr_tail.any? },
           "the stderr drainer must capture the flood for diagnostics"
  ensure
    File.delete(script_file.path) if script_file && File.exist?(script_file.path)
  end

  # Client#start! re-opens the transport after a child died on its own; the
  # dead incarnation's pipes and waiter thread must be reaped first, not
  # overwritten (FD leak + unreaped child).
  def test_reopen_after_child_death_reaps_the_previous_incarnation
    @manager.add_server(
      "respawn_srv",
      { "command" => @ruby, "args" => [@mock_server_file.path] },
      auto_start: true
    )

    client = @manager.client("respawn_srv")
    assert client&.running?

    transport = client.transport
    old_stdin = transport.instance_variable_get(:@stdin)
    old_wait_thr = transport.instance_variable_get(:@wait_thr)
    old_reader_thr = transport.instance_variable_get(:@reader_thr)

    Process.kill("KILL", transport.pid)
    assert wait_for(2.0) { !client.running? }, "child death must surface as a stopped transport"

    client.start!

    refute_equal old_stdin, transport.instance_variable_get(:@stdin)
    assert old_stdin.closed?, "the previous incarnation's stdin pipe must be closed, not leaked"
    assert old_wait_thr.join(1), "the previous waiter thread must have been joined (child reaped)"
    assert old_reader_thr.join(1), "the previous reader thread must have been joined"
    assert client.running?
    assert client.initialized
    assert client.list_tools(timeout: 5).is_a?(Array), "the re-opened transport must serve requests"
  end
end
