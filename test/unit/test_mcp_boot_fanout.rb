# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/mcp/manager"
require_relative "../../lib/rubik/concurrency"

# Config-boot fan-out through the concurrency boundary: server connect
# phases overlap (wall clock sum → max), tool registration stays in config
# order, per-server failure isolation and warning text stay byte-identical,
# apply-phase failures stop unapplied clients, and the kill switch restores
# the sequential boot. Fakes are injected through Manager's client_factory
# seam (mirroring http_factory in llm/client.rb) — no child processes here.
class TestMcpBootFanout < Minitest::Test
  # Fake stand-in for Rubik::MCP::Client: configurable connect latency and
  # tool list, records stop calls.
  class FakeClient
    attr_reader :name, :stopped
    attr_accessor :tools

    def initialize(name, latency: 0.0, fail: false, tools: [])
      @name = name
      @latency = latency
      @fail = fail
      @tools = tools
      @running = false
      @stopped = 0
    end

    def start!(*)
      sleep @latency
      raise Rubik::MCP::ConnectionError, "fake connect failure for #{name}" if @fail

      @running = true
      self
    end

    def list_tools(*)
      @tools
    end

    # Idempotent like the real Client#stop (Stdio#close early-returns once
    # stopped) — apply's rollback may stop via ctx drain AND explicitly.
    def stop
      return if @stopped.positive?

      @stopped += 1
      @running = false
    end

    def running?
      @running
    end
  end

  # Fake whose start! dies at Exception level mid-latency — the payload an
  # interrupt delivers into a scheduled fiber.
  class InterruptKillingClient < FakeClient
    def start!(*)
      sleep @latency
      raise Interrupt, "boot interrupted"
    end
  end

  def setup
    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
    Rubik::Concurrency.reset_disabled_cache!
    ENV.delete("RUBIK_FIBER_SCHEDULER")
  end

  def build_manager(clients)
    # rubocop:disable-next Lint/UnusedBlockArgument -- the kwargs document the DI contract
    factory = ->(cmd, args:, env:, name:, root_dir:, guard:) { clients.fetch(name) }
    @manager = Rubik::MCP::Manager.new(
      tools_registry: @tools_registry,
      context: @root_context,
      client_factory: factory
    )
  end

  def server_cfg(clients)
    hash = {}
    clients.each_key { |name| hash[name] = { "command" => "fake-#{name}" } }
    { "mcp.servers" => hash }
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def test_load_from_config_overlaps_server_connect_phases
    clients = {
      "slow-a" => FakeClient.new("slow-a", latency: 0.3, tools: [tool_def("tool_a")]),
      "slow-b" => FakeClient.new("slow-b", latency: 0.3, tools: [tool_def("tool_b")]),
      "slow-c" => FakeClient.new("slow-c", latency: 0.3, tools: [tool_def("tool_c")]),
      "slow-d" => FakeClient.new("slow-d", latency: 0.3, tools: [tool_def("tool_d")])
    }
    build_manager(clients)

    t0 = clock
    @manager.load_from_config(server_cfg(clients))
    wall = clock - t0

    assert_equal([:active, :active, :active, :active], clients.keys.map { |n| @manager.statuses[n] })
    # Serial floor is 4 × 0.3 s = 1.2 s; overlapped ≈ 0.3 s.
    assert_operator wall, :<, 0.8, "connect phases must overlap (serial floor 1.2s, took #{wall.round(2)}s)"
  end

  def test_tools_register_in_config_order_despite_completion_order
    clients = {
      # Config order fast-last; completion order reversed by latency.
      "first" => FakeClient.new("first", latency: 0.2, tools: [tool_def("tool_one")]),
      "second" => FakeClient.new("second", latency: 0.05, tools: [tool_def("tool_two")])
    }
    build_manager(clients)
    @manager.load_from_config(server_cfg(clients))

    assert_equal ["first", "second"], @manager.servers.keys.map(&:to_s)
    assert_equal ["mcp_first_tool_one", "mcp_second_tool_two"], @tools_registry.list.map(&:name)
  end

  def test_broken_server_does_not_block_others_and_logs_identical_warning
    clients = {
      "broken" => FakeClient.new("broken", fail: true),
      "healthy" => FakeClient.new("healthy", tools: [tool_def("ok_tool")])
    }
    build_manager(clients)

    _, err = capture_io do
      @manager.load_from_config(server_cfg(clients))
    end

    assert_equal :failed, @manager.statuses["broken"]
    assert_equal :active, @manager.statuses["healthy"]
    assert_match(/failed to load MCP server 'broken'.*ConnectionError.*fake connect failure/, err)
    assert_includes @tools_registry.list.map(&:name), "mcp_healthy_ok_tool"
  end

  def test_apply_phase_failure_stops_the_unapplied_prepared_client
    clients = {
      "one" => FakeClient.new("one", latency: 0.05, tools: [tool_def("one_tool")]),
      "two" => FakeClient.new("two", latency: 0.05, tools: [tool_def("two_tool")])
    }
    build_manager(clients)

    # Realistic post-wiring failure: registering server two's proxy tool
    # raises INSIDE apply_connected_server, after the context drain inverse
    # (client.stop) is wired. Apply's own rollback must stop the client;
    # the boot ensure must NOT double-stop it.
    def @tools_registry.register(proxy, origin: nil)
      raise "registry boom" if proxy.name.start_with?("mcp_two")

      super
    end

    _, err = capture_io do
      @manager.load_from_config(server_cfg(clients))
    end

    assert_equal :active, @manager.statuses["one"]
    assert_equal :failed, @manager.statuses["two"]
    assert_equal 1, clients["two"].stopped, "apply's rollback must stop the failed client exactly once"
    assert_equal 0, clients["one"].stopped, "the applied client keeps running"
    assert_match(/failed to load MCP server 'two'/, err)
  end

  def test_interrupt_during_connect_phase_stops_unapplied_clients
    # Exception-level death inside a connect (what a Ctrl-C interrupt
    # delivers) kills that slot's fiber before its capture assignment. K7
    # drains every item, then the Interrupt surfaces out of .map — phase 2
    # (apply) never runs. The boot ensure must still see the STARTED
    # healthy client through the side-effect slot capture and stop it: no
    # orphan child processes (with value-only capture, connected would be
    # [] here and every started client would leak).
    clients = {
      "fine" => FakeClient.new("fine", latency: 0.02, tools: [tool_def("fine_tool")]),
      "boom" => InterruptKillingClient.new("boom", latency: 0.3)
    }
    build_manager(clients)

    assert_raises Interrupt do
      @manager.load_from_config(server_cfg(clients))
    end

    assert_equal 1, clients["fine"].stopped, "the started-but-never-applied client must be stopped"
    # D10 (mcp-async-boot): the handshake rescue stops its own client even on
    # an Exception-level interrupt — a real interrupt mid-handshake leaves a
    # live spawned child behind otherwise. The fake never started, and stop is
    # idempotent, so the count is harmless.
    assert_equal 1, clients["boom"].stopped, "the interrupted handshake stops its own client"
    assert_empty @manager.clients, "nothing may be left registered mid-interrupt"
    # D6 (mcp-async-boot): the ensure sweep turns leftover :connecting marks
    # into :failed — a boot entry that never reached apply has a terminal
    # state, not the pre-boot :disabled.
    assert_equal :failed, @manager.statuses["fine"], "apply never ran"
  end

  def test_kill_switch_restores_sequential_boot
    ENV["RUBIK_FIBER_SCHEDULER"] = "off"
    Rubik::Concurrency.reset_disabled_cache!
    order = []
    clients = {
      "a" => sequenced_client("a", order),
      "b" => sequenced_client("b", order),
      "c" => sequenced_client("c", order)
    }
    build_manager(clients)

    @manager.load_from_config(server_cfg(clients))

    assert_equal ["a", "b", "c"], order, "kill-switched boot must connect strictly in config order"
    assert_equal([:active, :active, :active], clients.keys.map { |n| @manager.statuses[n] })
  end

  private

  def tool_def(tool_name)
    { "name" => tool_name, "description" => "fake", "inputSchema" => { "type" => "object" } }
  end

  def sequenced_client(name, order)
    FakeClient.new(name, tools: []).tap do |client|
      client.define_singleton_method(:start!) do |timeout: 10|
        order << name
        super(timeout: timeout)
      end
    end
  end
end
