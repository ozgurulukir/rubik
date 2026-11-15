# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require_relative "../../lib/rubik/mcp/boot_run"

# Unit tests for Rubik::MCP::BootRun (issue #453) driven through a fake
# manager: BootRun is the run object that owns entries / connected /
# outcomes / boot_epoch, so the fakes pin what BOOTRUN itself guarantees —
# sequential registration + application in config order, index-keyed
# fan-out slot capture, the ensure-choreography rollback (stop-debt rule),
# and the D5 epoch threading — not the manager's internal gates (those
# live in test_mcp_boot_guards.rb / test_mcp_boot_fanout.rb).
class TestMcpBootRun < Minitest::Test
  class FakeClient
    attr_reader :name, :stops

    def initialize(name)
      @name = name
      @stops = 0
    end

    def stop
      @stops += 1
    end
  end

  class FakeManager
    attr_reader :statuses

    def initialize(add_failures: {}, connect_outcomes: {}, apply_outcomes: {}, already_active: {}, registered: {})
      @add_failures = add_failures.transform_keys(&:to_s)
      @connect_outcomes = connect_outcomes.transform_keys(&:to_s) # name -> :ok | :raise | :interrupt | :sleep_then_ok
      @apply_outcomes = apply_outcomes.transform_keys(&:to_s)     # name -> :applied (default) | :skipped | :raise
      @already_active = already_active.transform_keys(&:to_s)     # name -> true (claim reports the slot owned)
      @registered = registered                                    # name -> client (the manager.client reader)
      @calls = []
      @statuses = Hash.new(:disabled)
    end

    # BootRun is a friend-class consumer: it `send`s into these seams, and
    # it also reads the trace, so expose both.
    attr_reader :calls

    def add_server(name, _defn, **_opts)
      name_str = name.to_s
      raise @add_failures.fetch(name_str) if @add_failures.key?(name_str)

      @calls << [:add_server, name_str]
    end

    def claim_boot_slot!(name, epoch)
      @calls << [:claim, name.to_s, epoch]
      @already_active[name.to_s] || false
    end

    def connect_server(name, _defn)
      @calls << [:connect_started, name.to_s]
      if @connect_outcomes[name.to_s] == :sleep_then_ok
        sleep 0.05 # let a shorter sibling overtake: exercises index-keyed capture
      end
      raise "connect boom" if @connect_outcomes[name.to_s] == :raise
      raise Interrupt if @connect_outcomes[name.to_s] == :interrupt

      client = FakeClient.new(name.to_s)
      @calls << [:connect_done, name.to_s, client]
      { client: client, tools: [{ "name" => "#{name}_tool" }] }
    end

    # BootRun reaches this through `send`, mirroring the friend-class seam.
    def boot_apply_gate(name, _defn, epoch, client:, tools:)
      @calls << [:apply, name.to_s, epoch, client, tools]
      case @apply_outcomes[name.to_s]
      when :skipped then :skipped
      when :raise then raise "apply boom"
      else :applied
      end
    end

    def transition_server!(name, to, epoch: nil)
      @calls << [:transition, name.to_s, to, epoch]
      @statuses[name.to_s] = to
    end

    def client(name)
      @registered[name.to_s]
    end

    def adopt(name, client)
      @registered[name.to_s] = client
    end

    def tool_count(_name)
      2
    end

    def emit_mcp_event(event, _level, name, **data)
      @calls << [:event, event, name.to_s, data]
    end
  end

  def setup
    skip "BootRun fan-out needs the fiber scheduler" if Rubik::Concurrency.disabled?
  end

  # Constructs @manager + @run; does NOT run the boot — tests drive
  # @run.run themselves so every test executes the run exactly once.
  def boot(**opts)
    servers_cfg = opts.delete(:servers_cfg) || cfg(:alpha, :beta)
    @manager = FakeManager.new(**opts)
    @run = Rubik::MCP::BootRun.new(@manager, servers_cfg, true)
    @run
  end

  def cfg(*names)
    names.to_h { |n| [n, { "command" => "fake-#{n}" }] }
  end

  def phase_calls(*kinds)
    @manager.calls.select { |entry| kinds.include?(entry[0]) }
  end

  def events
    phase_calls(:event)
  end

  def client_of(name)
    entry = @manager.calls.reverse.find { |e| e[0] == :connect_done && e[1] == name }
    entry && entry[2]
  end

  # ── Normal completion ──

  def test_normal_completion_aggregates_boot_results
    ret = nil
    @warnings = capture_stderr { ret = boot.run }

    assert_nil ret
    assert_equal [:applied, :applied], @run.outcomes.values_at(0, 1), "both slots must land :applied"
    assert_equal ["alpha", "beta"], @run.entries.map(&:first), "entries stay in config order"
    assert_equal true, @run.connected[0][:ok]
    assert_equal client_of("alpha"), @run.connected[0][:client]
    assert_equal [{ "name" => "alpha_tool" }], @run.connected[0][:tools]
    assert_equal true, @run.connected[1][:ok]

    # Registration order: add then claim, per server, in config order.
    assert_equal([:add_server, :claim, :add_server, :claim], phase_calls(:add_server, :claim).map { |e| e[0] })
    assert_equal ["alpha", "beta"], phase_calls(:add_server, :claim).map { |e| e[1] }.uniq
    claims = phase_calls(:claim)
    assert(claims.all? { |e| e[2].equal?(@run.boot_epoch) })

    # Success observability, in config order.
    assert_equal([:mcp_server_loaded, :mcp_server_loaded], events.map { |e| e[1] })
    assert_equal(["alpha", "beta"], events.map { |e| e[2] })
    assert_empty @warnings
  end

  def test_registration_failure_is_isolated_and_surfaced
    @manager = FakeManager.new(add_failures: { "bad" => RuntimeError.new("bad config") })
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:bad, :good), true)
    @warnings = capture_stderr { @run.run }

    assert_equal({ 0 => :applied }, @run.outcomes, "the healthy sibling still applies")
    refute_includes @run.entries.map(&:first), "bad", "a failed registration must not be claimed"
    refute_includes phase_calls(:add_server, :claim).map { |e| e[1] }, "bad"
    assert_match(/failed to load MCP server 'bad' \(RuntimeError: bad config\)/, @warnings)
    assert_equal [:mcp_server_failed, :mcp_server_loaded], events.map { |e| e[1] },
                 "the failure surfaces, the healthy sibling still loads"
    assert_equal(["bad", "good"], events.map { |e| e[2] })
    assert_equal "bad", events[0][2]
  end

  def test_disabled_and_non_hash_definitions_never_reach_the_claim
    servers_cfg = {
      "off" => { "command" => "c", "enabled" => false },
      "not_a_hash" => "garbage",
      "on" => { "command" => "c" }
    }
    boot(servers_cfg: servers_cfg)
    @warnings = capture_stderr { @run.run }

    assert_equal ["on"], @run.entries.map(&:first)
    # Registration itself happens for every Hash definition (auto_start is
    # forced false); only auto-start candidates reach the claim.
    assert_equal(["off", "on"], phase_calls(:add_server).map { |e| e[1] })
    assert_equal(["on"], phase_calls(:claim).map { |e| e[1] })
  end

  def test_mcp_disabled_boots_nothing
    @manager = FakeManager.new
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:alpha), false)
    ret = nil
    @warnings = capture_stderr { ret = @run.run }

    assert_nil ret
    assert_empty @run.entries
    assert_empty @run.outcomes
    # Registration still happens (auto_start forced false) but nothing is
    # claimed, connected, applied or swept.
    assert_equal [:add_server], @manager.calls.map { |e| e[0] }.uniq
  end

  # ── Failure paths ──

  def test_failing_connect_marks_the_slot_failed_with_the_boot_epoch
    @manager = FakeManager.new(connect_outcomes: { "boom" => :raise })
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:boom, :ok), true)
    @warnings = capture_stderr { @run.run }

    flips = phase_calls(:transition).select { |e| e[1] == "boom" }
    # Two flips: the apply-phase failure flip, then the D6 fail_orphans! sweep.
    assert_equal 2, flips.size
    assert flips.all? { |e| e == [:transition, "boom", :failed, @run.boot_epoch] },
           "both flips must carry THIS boot's epoch"
    refute @run.outcomes.key?(0), "a failed connect never enters the outcomes ledger"
    assert_equal [:applied], @run.outcomes.values_at(1)
    assert_match(/failed to load MCP server 'boom' \(RuntimeError: connect boom\)/, @warnings)
    assert_includes events.map { |e| e[1] }, :mcp_server_failed
  end

  def test_failing_apply_records_failed_and_never_double_stops_the_client
    boot(apply_outcomes: { "bad_apply" => :raise }, servers_cfg: cfg(:bad_apply))
    @warnings = capture_stderr { @run.run }

    assert_equal :failed, @run.outcomes[0], ":failed marks the slot so the ensure never double-stops"
    assert_equal 0, client_of("bad_apply").stops, "apply's own rollback drained the client; the ensure owes nothing"
    assert_match(/failed to load MCP server 'bad_apply' \(RuntimeError: apply boom\)/, @warnings)
  end

  def test_skipped_apply_owes_a_stop_for_the_prepared_client
    boot(apply_outcomes: { "alpha" => :skipped }, servers_cfg: cfg(:alpha))
    @run.run

    refute @run.outcomes.key?(0), "absence from the ledger = owes stop"
    assert_equal 1, client_of("alpha").stops, "skipping the apply must not orphan the prepared client"
  end

  def test_skipped_apply_spares_a_client_already_registered_by_the_manager
    # If the manager registered this exact client object anyway (e.g. a
    # racing enable picked it up), the rollback must not stop the live client.
    @manager = FakeManager.new(apply_outcomes: { "alpha" => :skipped })
    trace = lambda do |name, _defn|
      client = FakeClient.new(name.to_s)
      @manager.adopt(name.to_s, client)
      { client: client, tools: [] }
    end
    @manager.define_singleton_method(:connect_server) { |name, defn| trace.call(name, defn) }
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:alpha), true)

    @run.run

    refute @run.outcomes.key?(0)
    assert_equal 0, @manager.client("alpha").stops,
                 "a registered client (same object) is not stopped by the rollback"
  end

  def test_interrupt_mid_fanout_triggers_rollback_of_the_prepared_client
    @manager = FakeManager.new(connect_outcomes: { "slow" => :sleep_then_ok, "killer" => :interrupt })
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:slow, :killer), true)

    assert_raises(Interrupt) { @run.run }

    assert_equal 1, client_of("slow").stops,
                 "the ensure must stop the successfully-started client even though .map never returned"
    refute @run.outcomes.key?(0)
    sweeps = phase_calls(:transition).select { |e| e[2] == :failed }
    assert_includes sweeps, [:transition, "slow", :failed, @run.boot_epoch],
                    "fail_orphans! must terminalize entries that never reached apply"
  end

  # ── Fan-out ordering BootRun itself owns ──

  def test_fan_out_is_index_keyed_so_slots_stay_aligned_with_config_order
    # "slow" blocks long enough for "fast" to finish first; BootRun must
    # still capture each slot under ITS entry index, so phase 2 applies in
    # config order regardless of connect completion order.
    @manager = FakeManager.new(connect_outcomes: { "slow" => :sleep_then_ok })
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:slow, :fast), true)
    @run.run

    connect_done_order = phase_calls(:connect_done).map { |e| e[1] }
    assert_equal ["fast", "slow"], connect_done_order, "the fan-out itself must actually overlap"
    apply_order = phase_calls(:apply).map { |e| e[1] }
    assert_equal ["slow", "fast"], apply_order, "apply must stay in config order"
    assert_equal client_of("slow"), @run.connected[0][:client], "index-keyed capture keeps slots aligned"
    assert_equal client_of("fast"), @run.connected[1][:client]
    assert_equal [:applied, :applied], @run.outcomes.values_at(0, 1)
  end

  # ── D5 race gate: epoch identity ──

  def test_d5_epoch_is_threaded_through_claim_apply_and_sweeps
    @manager = FakeManager.new(connect_outcomes: { "boom" => :raise })
    @run = Rubik::MCP::BootRun.new(@manager, cfg(:boom, :ok), true)
    @run.run

    phase_calls(:claim).all? { |e| e[2].equal?(@run.boot_epoch) } ||
      flunk("every claim must carry the run's epoch")
    phase_calls(:apply).all? { |e| e[2].equal?(@run.boot_epoch) } ||
      flunk("the apply gate must receive the run's epoch")
    phase_calls(:transition).all? { |e| e[3].nil? || e[3].equal?(@run.boot_epoch) } ||
      flunk("sweeps and failure flips must never forge a foreign epoch")

    # A fresh epoch per run: two runs never share epoch identity.
    second = Rubik::MCP::BootRun.new(@manager, cfg(:ok), true)
    refute_equal @run.boot_epoch, second.boot_epoch
  end

  def test_already_active_slot_is_not_claimed_into_entries
    boot(already_active: { "alpha" => true, "beta" => true })
    @warnings = capture_stderr { @run.run }

    assert_empty @run.entries, "a slot owned by a live server must not boot"
    assert_empty @run.outcomes
    refute_includes phase_calls(:connect_started).map { |e| e[1] }, "alpha"
  end

  private

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
