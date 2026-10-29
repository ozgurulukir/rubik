# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require_relative "../../lib/rubik/mcp/manager"
require_relative "../../lib/rubik/repl/commands/mcp"

# Boot race guards (mcp-async-boot plan, slice 2): a user decision racing an
# in-flight boot always wins — disable/remove/stop_all/enable during boot
# never resurrect a server, never orphan a prepared client, and never apply
# into a dying manager. Determinism comes from a latch (Thread::Queue) inside
# the fake client: the boot thread parks mid-handshake until the test pulls
# the lever — no bare sleeps anywhere.
class TestMcpBootGuards < Minitest::Test
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

  class LatchedFailingClient < LatchedClient
    def start!(*)
      @running = true
      @entered << :in
      @release.pop
      raise Rubik::MCP::ConnectionError, "fake handshake failure after latch"
    end
  end

  def setup
    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @root_context&.dispose
  end

  def build_manager(supply)
    # Pops the next client for a name, so a racing enable_server gets its own
    # client instance while the boot thread holds the first one. kwargs beyond
    # name are the DI contract (connect_server passes them all).
    factory = lambda { |_cmd, name:, **_di_kwargs|
      supply[name].pop
    }
    @manager = Rubik::MCP::Manager.new(
      tools_registry: @tools_registry,
      context: @root_context,
      client_factory: factory
    )
  end

  def server_cfg(name)
    { "mcp.servers" => { name => { "command" => "fake-#{name}" } } }
  end

  def boot_in_thread(cfg)
    Thread.new { @manager.load_from_config(cfg) }
  end

  def tool_def(tool_name)
    { "name" => tool_name, "description" => "fake", "inputSchema" => { "type" => "object" } }
  end

  def test_disable_during_boot_wins_and_boot_client_is_stopped
    boot_client = LatchedClient.new("s", tools: [tool_def("boot_tool")])
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client })

    boot = boot_in_thread(server_cfg("s"))
    assert boot_client.entered?, "boot must reach the handshake"
    assert_equal :connecting, @manager.statuses["s"]

    @manager.disable_server("s")

    boot_client.release!
    boot.join(5)

    assert_equal :disabled, @manager.statuses["s"], "the user disable must survive the boot"
    assert_empty @manager.clients
    assert_equal 1, boot_client.stopped_count, "the skipped boot client must be stopped exactly once"
    assert_empty @tools_registry.list, "no boot tool may be registered"
  end

  def test_remove_during_boot_does_not_resurrect_the_server
    boot_client = LatchedClient.new("s", tools: [tool_def("boot_tool")])
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client })

    boot = boot_in_thread(server_cfg("s"))
    assert boot_client.entered?

    @manager.remove_server("s")

    boot_client.release!
    boot.join(5)

    refute @manager.servers.key?("s"), "a removed server must not resurrect when the boot applies"
    refute @manager.statuses.key?("s")
    assert_empty @manager.clients
    assert_equal 1, boot_client.stopped_count
  end

  def test_stop_all_during_boot_never_applies_into_the_dying_manager
    boot_client = LatchedClient.new("s", tools: [tool_def("boot_tool")])
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client })

    boot = boot_in_thread(server_cfg("s"))
    assert boot_client.entered?

    # Slice-3 stop_all joins the boot thread (bounded): it blocks here until
    # the release below lets the boot thread pass its @stopped gate.
    stopper = Thread.new { @manager.stop_all }
    boot_client.release!
    stopper.join(5)
    boot.join(5)

    assert_equal :disabled, @manager.statuses["s"]
    assert_empty @manager.clients
    assert_equal 1, boot_client.stopped_count
    assert_predicate @manager, :stopped?
  end

  def test_enable_during_boot_keeps_the_enable_client
    boot_client = LatchedClient.new("s", tools: [tool_def("boot_tool")])
    enable_client = LatchedClient.new("s", tools: [tool_def("enable_tool")], latch: false)
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client << enable_client })

    boot = boot_in_thread(server_cfg("s"))
    assert boot_client.entered?

    @manager.enable_server("s")
    assert_equal :active, @manager.statuses["s"]

    boot_client.release!
    boot.join(5)

    assert_equal :active, @manager.statuses["s"], "the enable decision must survive the boot"
    assert_empty @manager.clients.select { |_, c| c.equal?(boot_client) }, "the boot client must not be registered"
    assert_equal 1, boot_client.stopped_count, "the skipped boot client must be stopped"
    assert_equal 0, enable_client.stopped_count, "the enabled client keeps running"
    assert_includes @tools_registry.list.map(&:name), "mcp_s_enable_tool"
    refute_includes @tools_registry.list.map(&:name), "mcp_s_boot_tool"
  end

  def test_status_badge_shows_connecting
    boot_client = LatchedClient.new("s", latch: false)
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client })
    @manager.add_server("s", { "command" => "c" }, auto_start: false, persist: nil)
    # Public guarded seam (disabled -> connecting is a declared edge; user
    # actor, no epoch) — the raw statuses hash is no longer writable.
    @manager.transition_server!("s", :connecting)

    out = StringIO.new
    ctx = Struct.new(:out, :mcp_manager).new(out, @manager)
    Rubik::REPL::Commands::Mcp.status_servers(ctx, @manager)

    assert_includes out.string, "[CONNECTING]"
  end

  def test_disable_during_boot_survives_a_failing_handshake
    boot_client = LatchedFailingClient.new("s", tools: [tool_def("boot_tool")])
    build_manager(Hash.new { |h, k| h[k] = Queue.new }.tap { |h| h["s"] << boot_client })

    boot = boot_in_thread(server_cfg("s"))
    assert boot_client.entered?, "boot must reach the handshake"
    assert_equal :connecting, @manager.statuses["s"]

    @manager.disable_server("s")

    boot_client.release!
    boot.join(5)

    assert_equal :disabled, @manager.statuses["s"], "the connect failure must not clobber the user disable"
    assert_empty @manager.clients
    assert_equal 1, boot_client.stopped_count, "the skipped boot client must be stopped exactly once"
  end

  def test_apply_connected_server_rollback_logs_warning_on_stop_failure
    client = Object.new
    def client.stop
      raise "Stop socket closed"
    end

    def client.running?
      false
    end

    manager = Rubik::MCP::Manager.new
    bad_registry = Object.new
    def bad_registry.register(*_args, **_kwargs)
      raise "Registry crash"
    end
    manager.instance_variable_set(:@tools_registry, bad_registry)

    logged = []
    capture_log = lambda do |channel, msg|
      logged << [channel, msg] if channel == :mcp
    end

    Rubik::Log.stub(:warn, capture_log) do
      assert_raises(RuntimeError) do
        manager.apply_connected_server("failing_server", {}, client: client, tools: [{ "name" => "test" }])
      end
    end

    assert_equal :failed, manager.statuses["failing_server"]
    warn_entry = logged.find { |_c, m| m.include?("failed to stop rolled-back MCP client 'failing_server'") }
    refute_nil warn_entry, "Expected warning about stop failure during apply rollback"
    assert_includes warn_entry[1], "Stop socket closed"
  end
end
