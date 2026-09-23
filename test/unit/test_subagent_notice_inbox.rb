# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/subagent_notice_inbox"

# Unit pins for the Loop-side notice inbox (fresh-scan card 4): the queue
# mechanics that previously lived inline in orchestrator/loop.rb and were
# only testable through Loop.allocate ivar pokes.
class TestSubagentNoticeInbox < Minitest::Test
  def setup
    @inbox = Rubik::Orchestrator::SubagentNoticeInbox.new
  end

  def test_enqueue_then_drain_all_returns_notices_in_fifo_order
    @inbox.enqueue({ kind: :completed, id: "subagent-1", role: "A", state: "completed" })
    @inbox.enqueue({ kind: :completed, id: "subagent-2", role: "B", state: "completed" })

    drained = @inbox.drain_all
    assert_equal(["subagent-1", "subagent-2"], drained.map { |n| n[:id] })
  end

  def test_drain_all_on_empty_inbox_exercises_the_threaderror_terminator
    assert_equal [], @inbox.drain_all
  end

  def test_second_drain_all_returns_nothing
    @inbox.enqueue({ kind: :completed, id: "subagent-1", role: "A", state: "completed" })
    @inbox.drain_all

    assert_equal [], @inbox.drain_all
  end

  def test_enqueue_rejects_legacy_string_dialect_with_pinned_message
    error = assert_raises(ArgumentError) { @inbox.enqueue("⚡ legacy string") }
    assert_equal "subagent notice must be a Hash with :kind, got \"⚡ legacy string\"", error.message
  end

  def test_enqueue_rejects_hash_without_kind
    assert_raises(ArgumentError) { @inbox.enqueue({ id: "subagent-1", role: "A", state: "completed" }) }
  end

  def test_reset_for_new_run_discards_pending_and_rearms
    @inbox.enqueue({ kind: :completed, id: "stale-1", role: "Ghost", state: "completed" })
    @inbox.reset_for_new_run!

    assert_equal [], @inbox.drain_all
    @inbox.enqueue({ kind: :completed, id: "fresh-1", role: "New", state: "completed" })
    assert_equal(["fresh-1"], @inbox.drain_all.map { |n| n[:id] })
  end

  def test_keep_for_continuation_preserves_pending_notices
    notice = { kind: :completed, id: "subagent-1", role: "A", state: "completed" }
    @inbox.enqueue(notice)

    assert_nil @inbox.keep_for_continuation
    assert_equal [notice], @inbox.drain_all
  end

  def test_concurrent_enqueue_is_lock_free_safe
    threads = Array.new(4) do |i|
      Thread.new do
        25.times { |j| @inbox.enqueue({ kind: :completed, id: "w#{i}-#{j}", role: "R", state: "completed" }) }
      end
    end
    threads.each(&:join)

    assert_equal 100, @inbox.drain_all.size
  end
end
