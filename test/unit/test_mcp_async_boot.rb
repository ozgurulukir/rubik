# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require_relative "../../lib/rubik/mcp/manager"

# Async background config boot (mcp-async-boot plan, slice 3): load_from_config
# with async: true spawns a named boot thread and returns it, the boot applies
# only after the connect latches release, stop_all drains the thread, and the
# @stopped gate re-arms cleanly for repeated boots. The lifecycle wiring is
# pinned separately through a real Shell.
class TestMcpAsyncBoot < Minitest::Test
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
    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
  end

  def build_manager(client)
    # kwargs beyond name are the DI contract (connect_server passes them all).
    factory = ->(_cmd, **_di_kwargs) { client }
    @manager = Rubik::MCP::Manager.new(
      tools_registry: @tools_registry,
      context: @root_context,
      client_factory: factory
    )
  end

  def server_cfg(name)
    { "mcp.servers" => { name => { "command" => "fake-#{name}" } } }
  end

  def wait_until(timeout = 5.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    true
  end

  def tool_def(tool_name)
    { "name" => tool_name, "description" => "fake", "inputSchema" => { "type" => "object" } }
  end

  def test_async_boot_returns_named_thread_and_does_not_block
    client = LatchedClient.new("s", tools: [tool_def("t")])
    build_manager(client)

    thread = @manager.load_from_config(server_cfg("s"), async: true)

    assert_instance_of Thread, thread
    assert_equal "rubik-mcp-boot", thread.name
    assert client.entered?, "the boot must reach the handshake"
    assert thread.alive?
    refute_equal :active, @manager.statuses["s"], "the boot must not have applied while parked"

    client.release!
    assert thread.join(5)

    assert_equal :active, @manager.statuses["s"]
    assert_includes @tools_registry.list.map(&:name), "mcp_s_t"
  end

  def test_sync_boot_still_applies_inline_and_returns_nil
    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client)

    result = @manager.load_from_config(server_cfg("s"))

    assert_nil result
    assert_equal :active, @manager.statuses["s"]
  end

  def test_async_boot_failure_marks_failed_and_warns_once
    client = FailingClient.new("broken")
    build_manager(client)

    _, err = capture_io do
      thread = @manager.load_from_config(server_cfg("broken"), async: true)
      thread.join(5)
    end

    assert_equal :failed, @manager.statuses["broken"]
    assert_match(/failed to load MCP server 'broken'/, err)
  end

  def test_stop_all_joins_the_boot_thread_before_returning
    client = LatchedClient.new("s")
    build_manager(client)
    thread = @manager.load_from_config(server_cfg("s"), async: true)
    assert client.entered?

    stop_done = Queue.new
    Thread.new do
      @manager.stop_all(join_timeout: 5)
      stop_done << :done
    end
    # The stopper must stay parked in join while the boot thread is parked in
    # its handshake (0.3s probe against a 5s join bound).
    refute wait_until(0.3) { !stop_done.empty? }, "stop_all must not return while the boot thread is parked"

    client.release!
    assert wait_until { !stop_done.empty? }, "stop_all must return once the boot thread drains"
    assert thread.join(5)

    assert_equal :disabled, @manager.statuses["s"]
    assert_empty @manager.clients
    assert_equal 1, client.stopped_count, "the skipped boot client must be stopped exactly once"
  end

  def test_stop_all_join_timeout_expires_with_boot_still_parked
    client = LatchedClient.new("s")
    build_manager(client)
    thread = @manager.load_from_config(server_cfg("s"), async: true)
    assert client.entered?

    @manager.stop_all(join_timeout: 0.05)

    assert_predicate @manager, :stopped?, "the gate arms even when the join expires"

    client.release!
    assert thread.join(5)

    assert_equal :disabled, @manager.statuses["s"]
    assert_equal 1, client.stopped_count
  end

  def test_sync_boot_after_stop_all_reopens_the_stop_gate
    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client)
    @manager.stop_all

    result = @manager.load_from_config(server_cfg("s"))

    assert_nil result
    assert_equal :active, @manager.statuses["s"], "a sync boot with no boot thread alive must re-open the gate"
  end

  def test_async_boot_after_stop_all_resets_the_stop_gate
    client = LatchedClient.new("s", tools: [tool_def("t")], latch: false)
    build_manager(client)
    @manager.stop_all

    thread = @manager.load_from_config(server_cfg("s"), async: true)
    thread.join(5)

    assert_equal :active, @manager.statuses["s"], "a new boot must re-open the @stopped gate"
  end

  def test_repeated_async_boots_drain_the_previous_thread
    client = LatchedClient.new("s", latch: false)
    build_manager(client)

    first = @manager.load_from_config(server_cfg("s"), async: true)
    assert first.join(5)
    second = @manager.load_from_config(server_cfg("s"), async: true)
    assert second.join(5)

    assert_equal :active, @manager.statuses["s"]
  end

  # A boot whose body finishes before the spawning thread installs its
  # handle must not park a dead Thread object in @boot_thread: the sync
  # path re-opens the @stopped gate only when that handle is nil, so a
  # dead handle wedged there silences every later sync boot. The natural
  # interleaving is a microsecond race, so it is forced here: the spawner
  # is parked inside Thread#name= (which runs just before handle
  # installation) until the instant boot body has fully finished — the
  # ensure then finds no handle to clear, and the spawner installs a dead
  # Thread. Pre-fix that parks forever; post-fix the same hold retires it.
  def test_fast_async_boot_never_parks_a_dead_thread_handle
    build_manager(LatchedClient.new("s", latch: false))
    body_done = Queue.new
    @manager.define_singleton_method(:perform_load_from_config) do |_cfg = nil|
      body_done << :done
      nil
    end

    release_spawner = Queue.new
    thread_cls = Thread
    thread_cls.alias_method :original_name_for_race, :name=
    thread_cls.define_method(:name=) do |*args|
      result = thread_cls.instance_method(:original_name_for_race).bind_call(self, *args)
      release_spawner.pop
      result
    end

    spawner = Thread.new do
      @manager.load_from_config(server_cfg("s"), async: true)
    end
    body_done.pop
    release_spawner << :go
    assert spawner.join(5), "the parked spawner must resume and install the handle"

    assert_nil @manager.instance_variable_get(:@boot_thread),
               "a finished boot must never leave a dead thread handle in @boot_thread"

    # The observable damage: with the handle retired, a later sync boot
    # must find the @stopped gate open again.
    @manager.singleton_class.remove_method(:perform_load_from_config)
    @manager.stop_all
    @manager.load_from_config(server_cfg("s"))

    assert_equal :active, @manager.statuses["s"],
                 "a sync boot after a finished async boot must re-open the @stopped gate"
  ensure
    begin
      release_spawner << :go
    rescue StandardError
      nil
    end
    thread_cls.remove_method :name=
    thread_cls.alias_method :name=, :original_name_for_race
    thread_cls.remove_method :original_name_for_race
  end

  def test_warm_up_passes_the_env_aware_async_flag_to_the_manager
    recorded = []
    manager_cls = Rubik::MCP::Manager
    manager_cls.alias_method :original_load_for_spy, :load_from_config
    manager_cls.define_method(:load_from_config) do |_cfg = nil, async: false|
      recorded << async
      nil
    end
    begin
      config = Rubik::Config.new(root_dir: Dir.mktmpdir("mcp_lc"), home_dir: Dir.mktmpdir("mcp_lh"))
      shell = Rubik::REPL::Shell.new(config: config, output: StringIO.new, root_dir: Dir.mktmpdir("mcp_root"))
      assert_equal [false], recorded, "RUBIK_TEST=1 must boot synchronously by default"

      recorded.clear
      config.set("mcp.async_load", true, persist: nil)
      shell2 = Rubik::REPL::Shell.new(config: config, output: StringIO.new, root_dir: Dir.mktmpdir("mcp_root2"))
      assert_equal [true], recorded, "an explicit knob forces the async boot"
      shell2.stop
      shell.stop
    ensure
      manager_cls.remove_method :load_from_config
      manager_cls.alias_method :load_from_config, :original_load_for_spy
      manager_cls.remove_method :original_load_for_spy
    end
  end
end
