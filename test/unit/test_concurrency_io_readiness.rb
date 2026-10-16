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
end
