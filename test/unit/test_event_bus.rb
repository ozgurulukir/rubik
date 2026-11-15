# frozen_string_literal: true

require_relative "../test_helper"

class TestEventBus < Minitest::Test
  def test_subscribe_and_emit
    bus = Rubik::EventBus.new
    received = []
    bus.subscribe(:file_changed) { |payload| received << payload[:path] }

    bus.emit(:file_changed, path: "lib/rubik.rb")
    assert_equal ["lib/rubik.rb"], received
  end

  def test_subscriber_exception_does_not_crash_emitter
    log_output = StringIO.new
    bus = Rubik::EventBus.new(logger: Logger.new(log_output))
    second_called = false

    bus.subscribe(:test_event) { raise "Subscriber boom!" }
    bus.subscribe(:test_event) { second_called = true }

    bus.emit(:test_event)
    assert second_called, "Second subscriber should be called despite first subscriber exception"
    assert_includes log_output.string, "Subscriber boom!"
  end

  def test_unsubscribe_removes_exactly_that_listener
    bus = Rubik::EventBus.new
    received = []
    token = bus.subscribe(:file_changed) { |p| received << p[:path] }
    sibling = []
    bus.subscribe(:file_changed) { |p| sibling << p[:path] }

    bus.emit(:file_changed, path: "a")
    assert_equal ["a"], received

    bus.unsubscribe(:file_changed, token)
    bus.emit(:file_changed, path: "b")

    assert_equal ["a"], received, "Unsubscribed listener must not fire again"
    assert_equal ["a", "b"], sibling, "Sibling listener on the same event must keep firing"
  end

  def test_unsubscribe_with_unknown_listener_is_noop
    bus = Rubik::EventBus.new
    bus.unsubscribe(:file_changed, ->(p) { p }) # never subscribed; must not raise
    bus.emit(:file_changed, path: "x")
  end

  def test_post_and_drain
    bus = Rubik::EventBus.new
    received = []
    bus.subscribe(:task_finished) { |payload| received << payload[:task_id] }

    bus.post(:task_finished, task_id: "t-1")
    bus.post(:task_finished, task_id: "t-2")
    assert bus.drain!
    assert_equal ["t-1", "t-2"], received
  ensure
    bus&.stop
  end
end

# The default logger kwarg must route through Rubik::Log (level filter +
# single-line format), not construct a raw Logger.new($stderr) at require
# time (consistency sweep 2026-11-15).
class TestEventBusDefaultLoggerForwarding < Minitest::Test
  def test_default_logger_is_a_rubik_log_forwarder_that_emits
    capture = StringIO.new
    forwarder = nil
    begin
      orig_stderr = $stderr
      $stderr = capture
      forwarder = Rubik::Log.forwarder(:event_bus)
      forwarder.warn("probe message")
    ensure
      $stderr = orig_stderr
    end

    assert_kind_of Rubik::Log::Forwarder, forwarder
    assert_includes capture.string, "[rubik] warn event_bus: probe message"
  end

  def test_forwarder_respects_rubik_log_level
    forwarder = Rubik::Log.forwarder(:event_bus)
    capture = StringIO.new
    begin
      orig_stderr = $stderr
      $stderr = capture
      forwarder.debug("should be filtered at default warn level")
    ensure
      $stderr = orig_stderr
    end
    assert_empty capture.string, "debug must be filtered by the default RUBIK_LOG_LEVEL=warn"
  end
end
