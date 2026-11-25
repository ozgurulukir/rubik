# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/mcp/manager"

# Boot-thread slot/epoch seam (issue #653): Manager#load_from_config(async: true)
# drains the previous boot thread via join_boot_safely, mints a fresh epoch
# object, and installs an epoch-tagged slot (@boot_slot/@boot_thread) that the
# boot body's ensure clears only for its OWN epoch — a wedged older boot
# expiring past the drain bound must never clobber a newer boot's slot. This
# file pins those slot/epoch/join mechanics directly; the surrounding
# lifecycle wiring is covered by test_mcp_async_boot, test_mcp_boot_guards and
# the composability suite.
#
# Determinism: the boot body is parked on Thread::Queue latches through a
# per-instance perform_load_from_config override (the seam test_mcp_async_boot
# established), and the one case that would naturally block on the 2s
# join_boot_safely bound stubs Rubik::Concurrency::Join to report :timeout
# instantly — the exact outcome of that bound lapsing. No unbounded sleeps.
class TestMcpBootSlotSeam < Minitest::Test
  # Minimal client double for the one test that drives the real connect
  # path: start!/list_tools return immediately so the boot finishes before
  # the spawner's slot bookkeeping, exercising the fast-exit branch.
  class InstantClient
    attr_reader :stopped_count

    def initialize
      @stopped_count = 0
    end

    def start!(*)
      self
    end

    def list_tools(*)
      []
    end

    def stop
      @stopped_count += 1
    end

    def running?
      false
    end
  end

  def setup
    @manager = nil
    @root_context = nil
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
  end

  # Pin 1 — slot replacement on repeated async boots: the second boot
  # installs a NEW slot with a NEW epoch (new thread object), the returned
  # thread is the live one, and each finished boot's ensure clears its own
  # slot so repeated boots return the slot accumulator to baseline.
  def test_repeated_async_boots_replace_the_slot_with_a_fresh_epoch
    build_headless_manager
    latches = stub_parking_boot_body(@manager)

    @thread_a = @manager.load_from_config("boot_a", async: true)
    latches["boot_a"][:entered].pop
    # Race-free: the spawner installs the slot before load_from_config
    # returns, and the parked body keeps thread.alive? true until released.
    slot_a = boot_slot
    refute_nil slot_a, "the first boot must install its slot"
    assert_equal @thread_a, slot_a[:thread]
    assert_equal @thread_a, boot_thread

    release_and_join(latches["boot_a"], @thread_a) if latches
    refute @thread_a.alive?
    assert_nil boot_slot, "the finished boot's ensure must clear its own slot"
    assert_nil boot_thread

    @thread_b = @manager.load_from_config("boot_b", async: true)
    latches["boot_b"][:entered].pop
    slot_b = boot_slot
    assert_equal @thread_b, slot_b[:thread], "the slot must hold the live second boot's thread"
    refute_equal @thread_a, @thread_b, "the second boot must spawn a new thread object"
    assert_equal @thread_b, boot_thread
    assert_predicate @thread_b, :alive?
    refute_predicate @thread_a, :alive?
    refute_equal slot_a[:epoch], slot_b[:epoch], "each boot must mint a fresh epoch object"

    release_and_join(latches["boot_b"], @thread_b) if latches
    assert_nil boot_slot, "the replaced slot must also be cleared on exit"
    assert_nil boot_thread
  ensure
    release_and_join(latches["boot_a"], @thread_a) if latches
    release_and_join(latches["boot_b"], @thread_b) if latches
  end

  # Pin 2 — epoch invalidation: a wedged older boot A that finishes AFTER
  # boot B installed its slot must NOT clear B's slot — the epoch-tagged
  # ensure only clears when @boot_slot[:epoch] is its own epoch object.
  #
  # Stub note: in production B's entry drain join_boot_safely(2.0) would
  # block up to 2s against the still-parked A before proceeding. The stub
  # below makes Concurrency::Join.thread report :timeout immediately — the
  # exact outcome of that bound lapsing — forcing the
  # wedged-A-finishes-after-B interleaving deterministically. Minitest
  # restores the stub when the block returns. The drain's own :timeout warn
  # is captured via a Log stub in the same scope.
  def test_wedged_boot_finishing_after_a_newer_boot_cannot_clear_its_slot
    build_headless_manager
    latches = stub_parking_boot_body(@manager)

    # Boot A: no prior boot thread exists, so its entry drain is a real no-op.
    @thread_a = @manager.load_from_config("boot_a", async: true)
    latches["boot_a"][:entered].pop
    slot_a = boot_slot
    assert_equal @thread_a, slot_a[:thread]

    logged = []
    Rubik::Log.stub(:warn, ->(channel, msg) { logged << [channel, msg] if channel == :mcp }) do
      Rubik::Concurrency::Join.stub(:thread, ->(_handle, **_kwargs) { :timeout }) do
        @thread_b = @manager.load_from_config("boot_b", async: true)
      end
    end
    latches["boot_b"][:entered].pop
    slot_b = boot_slot
    assert_equal @thread_b, slot_b[:thread], "boot B must replace the wedged boot's slot"
    assert_equal @thread_b, boot_thread
    epoch_a = slot_a[:epoch]
    epoch_b = slot_b[:epoch]
    refute_equal epoch_a, epoch_b

    # A finishes NOW — with B's slot already installed. A's ensure must leave
    # B's slot and handle untouched.
    release_and_join(latches["boot_a"], @thread_a) if latches

    slot_after = boot_slot
    refute_nil slot_after, "the expired boot's ensure must not clear a newer boot's slot"
    assert_equal @thread_b, slot_after[:thread]
    assert slot_after[:epoch].equal?(epoch_b), "the surviving slot must still carry boot B's epoch"
    assert_equal @thread_b, boot_thread
    assert logged.any? { |(_channel, msg)| msg.include?("still alive after") },
           "the drain must have reported its expired join bound"

    release_and_join(latches["boot_b"], @thread_b) if latches
    assert_nil boot_slot
    assert_nil boot_thread
  ensure
    release_and_join(latches["boot_a"], @thread_a) if latches
    release_and_join(latches["boot_b"], @thread_b) if latches
  end

  # Pin 3 — join drain behavior on failure: a boot body that raises
  # StandardError is rescued inside the boot thread (warned on :mcp), #join
  # therefore never re-raises, the ensure clears the failed boot's own slot,
  # and the manager stays reusable for a follow-up async boot.
  #
  # Seam note: BootRun isolates per-server client failures (a client whose
  # start! raises is contained by the per-server rescue — pinned in
  # test_mcp_async_boot), so this drives the thread-body rescue directly:
  # the failure escapes the boot body itself, which is exactly the path the
  # rescue + epoch-tagged ensure choreography in load_from_config owns.
  def test_failed_async_boot_is_rescued_clears_its_slot_and_keeps_the_manager_reusable
    build_headless_manager
    recovered = Queue.new
    @manager.define_singleton_method(:perform_load_from_config) do |cfg = nil|
      raise StandardError, "simulated boot failure" if cfg == "failing_boot"

      recovered << :ok if cfg == "recovery_boot"
      nil
    end

    logged = []
    Rubik::Log.stub(:warn, ->(channel, msg) { logged << [channel, msg] if channel == :mcp }) do
      @thread = @manager.load_from_config("failing_boot", async: true)
      # (a) the body's rescue keeps the failure off #join: an unhandled
      # thread death would re-raise right here and fail the test.
      assert @thread.join(5), "the failed boot thread must finish, not die unhandled"
      warn_entry = logged.find { |(_channel, msg)| msg.include?("background MCP boot failed") }
      refute_nil warn_entry, "the failed boot must warn on the :mcp channel"
      assert_includes warn_entry[1], "StandardError: simulated boot failure"
    end

    # (b) the epoch-tagged ensure must clear the failed boot's own slot.
    assert_nil boot_slot
    assert_nil boot_thread

    # (c) the manager is reusable: a follow-up async boot runs its body clean.
    @recovery_thread = @manager.load_from_config("recovery_boot", async: true)
    assert wait_until(5) { !recovered.empty? }, "the follow-up boot body must run"
    assert @recovery_thread.join(5)
    assert_nil boot_slot, "the recovery boot must also retire its slot"
    assert_nil boot_thread
  ensure
    @thread&.join(5)
    @recovery_thread&.join(5)
  end

  # Pin 4 — fast-exit boot: when the boot body finishes before the spawner's
  # slot-assignment hold runs, no stale slot may be retained. Either
  # interleaving (ensure-before-install leaves nothing to install;
  # install-before-ensure is undone by the ensure's own-epoch clear) must
  # land on @boot_slot == @boot_thread == nil once the thread is joined.
  def test_fast_async_boot_leaves_no_slot_behind
    build_connected_manager(InstantClient.new)

    @thread = @manager.load_from_config(server_cfg("s"), async: true)

    assert @thread.join(5)
    refute @thread.alive?, "the returned thread must be the finished boot thread itself"
    assert_nil boot_slot, "a fast boot must not retain a stale slot"
    assert_nil boot_thread
    assert_equal :active, @manager.statuses["s"], "the fast boot must still have applied the server"
  ensure
    @thread&.join(5)
  end

  # Pin 5 — sync gate interaction: the sync path re-opens @stopped only when
  # no boot thread handle remains, so a wedged background boot keeps the
  # stop gate armed across sync boots ("wedged background boot stays gated
  # after stop_all"); once the handle is gone, the same sync boot re-opens it.
  def test_sync_boot_reopens_the_stop_gate_only_when_no_boot_thread_remains
    build_headless_manager
    wedge = Queue.new
    wedged = Thread.new { wedge.pop }
    @manager.instance_variable_set(:@boot_thread, wedged)
    @manager.instance_variable_set(:@stopped, true)

    @manager.load_from_config({ "mcp.servers" => {} })
    assert_predicate @manager, :stopped?,
                     "a wedged boot thread must keep the stop gate armed across sync boots"

    @manager.instance_variable_set(:@boot_thread, nil)
    @manager.load_from_config({ "mcp.servers" => {} })
    refute_predicate @manager, :stopped?,
                     "a sync boot with no boot thread remaining must re-open the stop gate"
  ensure
    begin
      wedge << :go
    rescue StandardError
      nil
    end
    wedged&.join(1)
  end

  private

  def build_headless_manager
    @manager = Rubik::MCP::Manager.new
  end

  def build_connected_manager(client)
    @root_context = Rubik::Runtime::Context.new
    # kwargs beyond name are the DI contract (connect_server passes them all).
    factory = ->(_cmd, **_di_kwargs) { client }
    @manager = Rubik::MCP::Manager.new(
      tools_registry: Rubik::Tools::Registry.new,
      context: @root_context,
      client_factory: factory
    )
  end

  def boot_slot
    @manager.instance_variable_get(:@boot_slot)
  end

  def boot_thread
    @manager.instance_variable_get(:@boot_thread)
  end

  def server_cfg(name)
    { "mcp.servers" => { name => { "command" => "fake-#{name}" } } }
  end

  # Parks the boot body on a per-config latch pair so each async boot's
  # interleaving is test-driven, not sleep-guessed.
  def stub_parking_boot_body(manager)
    latches = Hash.new { |h, cfg| h[cfg] = { entered: Queue.new, release: Queue.new } }
    manager.define_singleton_method(:perform_load_from_config) do |cfg = nil|
      latch = latches[cfg]
      latch[:entered] << :in
      latch[:release].pop
      nil
    end
    latches
  end

  # Idempotent lever: a second :go on an already-released latch is inert
  # (the thread popped once and returned), so body cleanup + ensure reuse.
  def release_and_join(latch, thread)
    begin
      latch[:release] << :go
    rescue StandardError
      nil
    end
    thread&.join(5)
  end
end
