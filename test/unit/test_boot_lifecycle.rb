# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/mcp/manager"

# Boot state machine (candidate 6): the TRANSITIONS vocabulary, the guarded
# transition_server! seam (epoch semantics, idempotence, StateError
# tripwire), the stop-debt rule, and the snapshot statuses door.
class TestBootLifecycle < Minitest::Test
  def setup
    @manager = Rubik::MCP::Manager.new
  end

  def teardown
    # No clients are ever started here; statuses-only churn needs no teardown.
  end

  def test_every_boot_state_is_pinned_to_the_vocabulary
    assert_equal [:active, :connecting, :disabled, :failed], Rubik::MCP::Manager::TRANSITIONS.keys.sort
    assert_equal [:active, :connecting, :disabled, :failed], Rubik::MCP::BootLifecycle::STATES.sort
  end

  def test_the_ghost_state_loaded_is_rejected_by_the_guarded_transition
    err = assert_raises(Rubik::MCP::BootLifecycle::StateError) do
      @manager.transition_server!("s", :loaded)
    end

    assert_includes err.message, "disabled -> loaded"
  end

  def test_same_state_transitions_are_idempotent_no_ops
    @manager.transition_server!("s", :connecting)

    assert_equal :connecting, @manager.transition_server!("s", :connecting)
    assert_equal :connecting, @manager.statuses["s"]
    assert_equal :disabled, @manager.transition_server!("absent", :disabled)
  end

  def test_a_boot_flip_from_a_stale_epoch_is_a_no_op
    epoch = Object.new
    refute @manager.claim_boot_slot!("s", epoch), "an unclaimed slot must not read as already active"
    assert_equal :connecting, @manager.statuses["s"]

    # A different boot's epoch does not own this mark.
    assert_nil @manager.transition_server!("s", :failed, epoch: Object.new)
    assert_equal :connecting, @manager.statuses["s"], "a stale-epoch flip must not touch the slot"

    # The owning epoch flips it.
    assert_equal :failed, @manager.transition_server!("s", :failed, epoch: epoch)
    assert_equal :failed, @manager.statuses["s"]
  end

  def test_a_user_transition_needs_no_epoch_and_wins_over_a_boot_mark
    epoch = Object.new
    @manager.claim_boot_slot!("s", epoch)
    assert_equal :connecting, @manager.statuses["s"]

    # User actor: no epoch, decision wins from any state (D5).
    assert_equal :disabled, @manager.transition_server!("s", :disabled)

    # The boot's mark died with the slot; its later flip is a no-op.
    assert_nil @manager.transition_server!("s", :failed, epoch: epoch)
    assert_equal :disabled, @manager.statuses["s"]
  end

  def test_leaving_connecting_retires_the_boot_mark_and_repeated_boot_cycles_stay_flat
    1000.times do
      epoch = Object.new
      @manager.claim_boot_slot!("s", epoch)
      assert_equal :connecting, @manager.statuses["s"]

      # claim/apply cycle
      @manager.transition_server!("s", :active, epoch: epoch)
      assert_empty boot_marks, "leaving :connecting must retire the boot mark (apply cycle)"

      # claim/remove cycle
      epoch2 = Object.new
      @manager.claim_boot_slot!("s", epoch2)
      @manager.clear_server_record!("s")
      assert_empty boot_marks, "record deletion must retire the boot mark (remove cycle)"
      refute @manager.statuses.key?("s")
    end
  end

  def test_owes_stop_ledger_marks_skipped_and_never_run_slots
    assert Rubik::MCP::BootLifecycle.owes_stop?(nil), "a never-ran slot owes a stop"
    assert Rubik::MCP::BootLifecycle.owes_stop?(:skipped), "a skipped slot owes a stop"
    refute Rubik::MCP::BootLifecycle.owes_stop?(:applied), "an applied slot stopped its own client"
    refute Rubik::MCP::BootLifecycle.owes_stop?(:failed), "a failed-apply slot rolled its own client back"
  end

  def test_statuses_reader_returns_an_isolated_snapshot
    @manager.transition_server!("s", :connecting)

    snapshot = @manager.statuses
    snapshot["s"] = :failed
    snapshot["injected"] = :active

    assert_equal :connecting, @manager.statuses["s"], "mutating the returned hash must not corrupt internal state"
    refute @manager.statuses.key?("injected")
  end

  private

  def boot_marks
    @manager.instance_variable_get(:@boot_marks)
  end
end
