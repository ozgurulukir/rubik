# frozen_string_literal: true

require_relative "../test_helper"

class TestConcurrencyIoReadiness < Minitest::Test
  def test_read_readiness_does_not_resume_a_writer
    reactor = Rubik::Concurrency::EventLoop.new
    io = Object.new
    writer = Fiber.new {}
    readers = { read: {}, write: { writer => 0 } }
    reactor.instance_variable_get(:@io_waiters)[io] = readers

    reactor.send(:wake_io, io, IO::READABLE)

    assert_empty reactor.instance_variable_get(:@runnable)
    assert_equal 0, readers[:write][writer]
  ensure
    reactor&.instance_variable_get(:@io_waiters)&.clear
    reactor&.shutdown
  end

  def test_write_readiness_does_not_resume_a_reader
    reactor = Rubik::Concurrency::EventLoop.new
    io = Object.new
    reader = Fiber.new {}
    waiters = { read: { reader => 0 }, write: {} }
    reactor.instance_variable_get(:@io_waiters)[io] = waiters

    reactor.send(:wake_io, io, IO::WRITABLE)

    assert_empty reactor.instance_variable_get(:@runnable)
    assert_equal 0, waiters[:read][reader]
  ensure
    reactor&.instance_variable_get(:@io_waiters)&.clear
    reactor&.shutdown
  end

  def test_select_watches_only_registered_readiness_directions
    reactor = Rubik::Concurrency::EventLoop.new
    reader = Object.new
    writer = Object.new
    fiber = Fiber.new {}
    interests = reactor.instance_variable_get(:@io_waiters)
    interests[reader] = { read: { fiber => 0 }, write: {} }
    interests[writer] = { read: {}, write: { fiber => 0 } }
    observed = nil
    select = lambda do |reads, writes, _timeout|
      observed = [reads, writes]
      :retry
    end

    reactor.stub(:safe_select, select) { reactor.send(:select_or_wait) }

    assert_equal [reader, reactor.instance_variable_get(:@wake_read)], observed[0]
    assert_equal [writer], observed[1]
  ensure
    reactor&.instance_variable_get(:@io_waiters)&.clear
    reactor&.shutdown
  end
end
