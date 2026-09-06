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
end
