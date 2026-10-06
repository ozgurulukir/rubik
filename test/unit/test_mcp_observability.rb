# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require_relative "../../lib/rubik/mcp/manager"

# Boot observability (mcp-async-boot plan, slice 4): boot outcomes publish
# through the session event bus (subsystem :mcp), land in the dmesg ring via
# the dispatcher door, the dmesg tool's subsystem enum knows "mcp", and the
# REPL prints async-boot notices through the terminal guard. Every bus-backed
# assertion drains first (post is queued, not synchronous).
class TestMcpObservability < Minitest::Test
  class LatchedClient
    attr_reader :name, :stopped_count

    def initialize(name, tools: [], latch: true)
      @name = name
      @tools = tools
      @latch = latch
      @entered = Queue.new
      @release = Queue.new
      @stopped_count = 0
      @running = false
    end

    def start!(*)
      @running = true
      @entered << :in if @latch
      @release.pop if @latch
      self
    end

    def list_tools(*)
      @tools
    end

    def stop
      @stopped_count += 1
      @running = false
    end

    def running?
      @running
    end

    def release!
      @release << :go
    end

    def entered?(timeout = 5.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while @entered.empty?
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.005
      end
      true
    end
  end

  class FailingClient < LatchedClient
    def start!(*)
      @entered << :in
      raise Rubik::MCP::ConnectionError, "fake handshake failure"
    end
  end

  def setup
    @ring = Rubik::Kernel::Dmesg.new(capacity: 50)
    @bus = Rubik::EventBus.new(dispatcher: Rubik::Kernel::Dispatcher.new(dmesg: @ring))
    @root_context = Rubik::Runtime::Context.new
    @root_context.provide(Rubik::Coeffects::EVENTS, @bus)
    @tools_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @manager&.stop_all
    @bus&.stop
    @root_context&.dispose
  end

  def build_manager(client, context: @root_context)
    # kwargs beyond name are the DI contract (connect_server passes them all).
    factory = ->(_cmd, **_di_kwargs) { client }
    @manager = Rubik::MCP::Manager.new(
      tools_registry: @tools_registry,
      context: context,
      client_factory: factory
    )
  end

  def server_cfg(name)
    { "mcp.servers" => { name => { "command" => "fake-#{name}" } } }
  end

  def tool_def(tool_name)
    { "name" => tool_name, "description" => "fake", "inputSchema" => { "type" => "object" } }
  end

  def mcp_records
    @ring.tail(50, subsystem: "mcp")
  end

  def test_successful_boot_records_loaded_event_with_tool_count
    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client)

    thread = @manager.load_from_config(server_cfg("s"), async: true)
    thread.join(5)
    @bus.drain!

    loaded = mcp_records.find { |r| r.message == "event:mcp_server_loaded" }
    refute_nil loaded, "a successful boot must post mcp_server_loaded"
    assert_equal :info, loaded.level
    assert_equal "s", loaded.data[:server]
    assert_equal 1, loaded.data[:tools]
  end

  def test_failed_boot_records_err_event_and_byte_identical_stderr_line
    client = FailingClient.new("broken")
    build_manager(client)

    _, err = capture_io do
      @manager.load_from_config(server_cfg("broken"))
    end
    @bus.drain!

    failed = mcp_records.find { |r| r.message == "event:mcp_server_failed" }
    refute_nil failed, "a failed handshake must post mcp_server_failed"
    assert_equal :err, failed.level
    assert_equal "broken", failed.data[:server]
    assert_match(/fake handshake failure/, failed.data[:error].to_s)
    assert_includes err, "[rubik] warn mcp: failed to load MCP server 'broken' (Rubik::MCP::ConnectionError: fake handshake failure)"
  end

  def test_headless_manager_without_a_bus_still_boots
    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client, context: nil)

    _, err = capture_io do
      @manager.load_from_config(server_cfg("s"))
    end

    assert_equal :active, @manager.statuses["s"]
    assert_empty mcp_records
    refute_match(/failed to emit MCP event/, err)
  end

  def test_phase0_registration_failure_records_failed_event_too
    build_manager(LatchedClient.new("s"))
    # A plugin-wrapped add_server that raises must surface in dmesg as a
    # boot failure, not just stderr (review round: phase-0 blind spot).
    def @manager.add_server(name, _defn = nil, **)
      raise ArgumentError, "wrapped add_server boom for #{name}"
    end

    _, err = capture_io do
      @manager.load_from_config(server_cfg("s"))
    end
    @bus.drain!

    failed = mcp_records.find { |r| r.message == "event:mcp_server_failed" }
    refute_nil failed, "a phase-0 registration failure must post mcp_server_failed"
    assert_equal :err, failed.level
    assert_equal "s", failed.data[:server]
    assert_match(/wrapped add_server boom/, failed.data[:error].to_s)
    assert_match(/failed to load MCP server 's'/, err)
  end

  def test_dmesg_tool_enum_knows_mcp_and_filters_by_it
    enum = Rubik::Tools::DmesgTool::DECLARATION.params_schema[:properties][:subsystem][:enum]
    assert_includes enum, "mcp"

    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client)
    @manager.load_from_config(server_cfg("s"))
    @bus.drain!

    out = Rubik::Tools::DmesgTool.new(@ring).execute("subsystem" => "mcp")
    assert_includes out, "mcp_server_loaded"
  end

  def test_boot_notices_render_through_the_terminal_guard
    out = StringIO.new
    guard = Rubik::REPL::TerminalGuard.new(output: out, reline: nil)
    runtime_manager = Rubik::Runtime::Manager.new
    shell = Object.new
    shell.extend(Rubik::REPL::Lifecycle)
    shell.instance_variable_set(:@event_bus, @bus)
    shell.instance_variable_set(:@runtime_manager, runtime_manager)
    shell.instance_variable_set(:@running, true)
    shell.instance_variable_set(:@output, out)
    shell.instance_variable_set(:@terminal_guard, guard)

    shell.wire_mcp_boot_notices!(async: true)
    @bus.emit(:mcp_server_loaded, { server: "x", tools: 3 }, subsystem: :mcp, level: :info)
    @bus.emit(:mcp_server_failed, { server: "y", error: "boom" }, subsystem: :mcp, level: :err)

    assert_includes out.string, "mcp: server 'x' ready (3 tools)"
    assert_includes out.string, "mcp: server 'y' failed (boom)"

    # Teardown unsubscribe: disposing the wiring context must not raise and
    # must detach the handlers.
    runtime_manager.context.dispose
    @bus.emit(:mcp_server_loaded, { server: "z", tools: 1 }, subsystem: :mcp, level: :info)
    refute_includes out.string, "server 'z'"
  end

  def test_notice_wiring_is_idempotent
    runtime_manager = Rubik::Runtime::Manager.new
    shell = Object.new
    shell.extend(Rubik::REPL::Lifecycle)
    shell.instance_variable_set(:@event_bus, @bus)
    shell.instance_variable_set(:@runtime_manager, runtime_manager)

    shell.wire_mcp_boot_notices!(async: true)
    first = shell.instance_variable_get(:@mcp_notice_tokens)
    shell.wire_mcp_boot_notices!(async: true)

    assert_same first, shell.instance_variable_get(:@mcp_notice_tokens)
    runtime_manager.context.dispose
  end
end
