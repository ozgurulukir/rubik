# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "rbconfig"

class TestConcurrencyIOProtocol < Minitest::Test
  def test_generic_socket_read_nonblock_preserves_http_read_timeout
    script = <<~'PROBE'
      require "net/http"
      require "rubik/concurrency"
      # Linux sockets bypass IO#read_nonblock through MSG_DONTWAIT. Remove
      # that optimization only in this subprocess to exercise macOS's path.
      if BasicSocket.instance_methods(false).include?(:read_nonblock)
        BasicSocket.class_eval { remove_method :read_nonblock }
      end
      begin
        server = TCPServer.new("127.0.0.1", 0)
      rescue Errno::EPERM, Errno::EACCES
        exit 77
      end
      worker = Thread.new do
        client = server.accept
        while (header = client.gets)
          break if header == "\r\n"
        end
        sleep 2
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      ensure
        client&.close
      end
      timed_out = false
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        Rubik::Concurrency.silently do
          http = Net::HTTP.new("127.0.0.1", server.addr[1])
          http.max_retries = 0
          http.read_timeout = 0.1
          begin
            http.get("/")
          rescue Net::ReadTimeout
            timed_out = true
          end
        end
      ensure
        worker.kill
        worker.join
        server.close
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      abort "timeout lost: timed_out=#{timed_out}, elapsed=#{elapsed}" unless timed_out && elapsed < 1.5
      abort "scheduler leaked" unless Fiber.scheduler.nil?
      puts "read timeout preserved"
    PROBE
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
    skip "Socket binding not permitted in this environment" if status.exitstatus == 77

    assert status.success?, "generic IO subprocess failed: #{status.inspect}\n#{output}\n#{error}"
    assert_includes output, "read timeout preserved"
  end

  def test_io_hooks_preserve_buffer_offsets_and_minimum_transfer_lengths
    reader, writer = IO.pipe
    buffer = IO::Buffer.new(8)
    buffer.set_string("........")
    writer.write("abc")
    writer.close
    loop = Rubik::Concurrency::EventLoop.new
    scheduler = Rubik::Concurrency::Scheduler.new(loop)
    assert_equal 3, scheduler.io_read(reader, buffer, 3, 2)
    assert_equal "..abc...", buffer.get_string
    reader.close

    reader, writer = IO.pipe
    assert_equal 6, scheduler.io_write(writer, buffer, 3, 2)
    writer.close
    assert_equal "abc...", reader.read
  ensure
    [reader, writer].each { |io| io&.close unless io&.closed? }
    buffer&.free
    loop&.shutdown
  end
end
