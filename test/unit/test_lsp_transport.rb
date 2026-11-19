# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Focused unit tests for Rubik::LSP::Transport (issue #470). The transport
# was extracted from LSP::Client precisely so these phases — framing writes,
# response correlation, reader-thread lifecycle and the stop/shutdown
# inverse — can be exercised WITHOUT stubbing the whole client. No process
# is spawned: a pipe pair doubles the server side of the stdio channel.
class TestLSPTransport < Minitest::Test
  def setup
    @to_server_r, @to_server_w = IO.pipe
    @from_server_r, @from_server_w = IO.pipe
    # Binary mode on BOTH ends of both pipes: LSP JSON-RPC framing is
    # byte-exact CRLF, and Windows text-mode IO silently rewrites it —
    # the read side translates CRLF→LF (a framed header arrives as
    # "Content-Length: 45\n" and the framing assertion fails), while the
    # write side expands every \n to \r\n, corrupting Content-Length
    # counts. Production Transport#spawn binmodes its pipes for exactly
    # this reason; the test fixture must match.
    [@to_server_r, @to_server_w, @from_server_r, @from_server_w].each(&:binmode)
    @protocol_messages = []
    @transport = Rubik::LSP::Transport.new(
      root_dir: Dir.pwd,
      on_message: ->(msg) { @protocol_messages << msg }
    )
    @transport.instance_variable_set(:@stdin, @to_server_w)
    @transport.instance_variable_set(:@stdout, @from_server_r)
  end

  def teardown
    begin
      @to_server_r.close
    rescue
      nil
    end
    begin
      @to_server_w.close
    rescue
      nil
    end
    begin
      @from_server_r.close
    rescue
      nil
    end
    begin
      @from_server_w.close
    rescue
      nil
    end
    @transport.shutdown
  end

  def framed(body)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def test_new_transport_is_inert
    refute @transport.running
    refute @transport.alive?
    refute @transport.crashed?
    refute @transport.stale?
    assert_equal 0, @protocol_messages.size
  end

  def test_write_message_frames_bytes_exactly
    assert @transport.write_message({ jsonrpc: "2.0", method: "ping", params: {} })
    header = @to_server_r.gets
    assert_match(/\AContent-Length: \d+\r\n\z/, header)
    len = header.split(":", 2).last.strip.to_i
    assert_equal "\r\n", @to_server_r.read(2)
    body = @to_server_r.read(len)
    parsed = JSON.parse(body)
    assert_equal "ping", parsed["method"]
    assert_equal "2.0", parsed["jsonrpc"]
  end

  def test_reader_thread_correlates_response_and_wakes_waiter
    @transport.start_reader_thread
    @transport.instance_variable_get(:@pending_requests)[7] = 0.0
    @from_server_w.write(framed({ "jsonrpc" => "2.0", "id" => 7, "result" => { "ok" => true } }.to_json))
    @from_server_w.flush

    result = @transport.wait_for_response(7, timeout: 2)
    assert_equal({ "ok" => true }, result)
  end

  def test_server_request_and_notification_go_to_on_message_not_correlation
    @transport.start_reader_thread
    @transport.instance_variable_get(:@pending_requests)[3] = 0.0

    @from_server_w.write(framed({ "jsonrpc" => "2.0", "id" => 3, "method" => "workspace/configuration", "params" => {} }.to_json))
    @from_server_w.write(framed({ "jsonrpc" => "2.0", "method" => "textDocument/publishDiagnostics", "params" => { "uri" => "file:///x.rb", "diagnostics" => [] } }.to_json))
    @from_server_w.flush

    wait_until { @protocol_messages.size == 2 }
    assert_equal "workspace/configuration", @protocol_messages.first["method"]
    assert_equal "textDocument/publishDiagnostics", @protocol_messages.last["method"]
    # Server request IDs must never satisfy a pending client request (issue #206).
    error = assert_raises(Rubik::LSP::Transport::RequestError) do
      @transport.wait_for_response(3, timeout: 0.05)
    end
    assert_equal :timeout, error.reason
  end

  def test_late_response_for_non_pending_id_is_discarded
    @transport.start_reader_thread
    @from_server_w.write(framed({ "jsonrpc" => "2.0", "id" => 99, "result" => nil }.to_json))
    @from_server_w.flush
    wait_until { !@transport.instance_variable_get(:@responses).empty? }

    error = assert_raises(Rubik::LSP::Transport::RequestError) do
      @transport.wait_for_response(1, timeout: 0.05)
    end
    assert_equal :timeout, error.reason
  end

  def test_reader_eof_marks_crashed_and_fails_pending_requests
    @transport.instance_variable_set(:@running, true)
    @transport.start_reader_thread
    @transport.instance_variable_get(:@pending_requests)[1] = 0.0

    @from_server_w.close # EOF for the reader

    error = assert_raises(Rubik::LSP::Transport::RequestError) do
      @transport.wait_for_response(1, timeout: 2)
    end
    assert_equal :reader_failure, error.reason
    assert @transport.crashed?, "reader EOF while running must mark the transport crashed"
    refute @transport.alive?
  end

  # Dead waiter double: shutdown skips its kill_tree branch when the waiter
  # reports dead (mirrors the DeadWaiter pattern in the client error paths).
  class FakeWaiter
    def pid = 4_242_424

    def alive? = false

    def join(*) = nil

    def kill = nil
  end

  # Never makes write progress: write_until must hit its deadline instead of
  # parking forever on @write_mutex (issue #555).
  class StalledStdin
    def closed? = false
    def write_nonblock(*) = :wait_writable
    def wait_writable(*) = true
    def flush; end
    def close; end
  end

  def fake_waiter
    @fake_waiter ||= FakeWaiter.new
  end

  def test_shutdown_retracts_resources_and_is_idempotent_safe
    reader = Thread.new { sleep 30 }
    @transport.instance_variable_set(:@reader_thr, reader)
    @transport.instance_variable_set(:@wait_thr, fake_waiter)
    @transport.instance_variable_set(:@running, true)

    @transport.shutdown

    refute @transport.running
    refute @transport.crashed?
    assert @to_server_w.closed?
    assert @from_server_r.closed?
    assert_nil @transport.instance_variable_get(:@reader_thr)
  end

  def test_write_message_uses_deadline_bounded_write
    @transport.instance_variable_set(:@stdin, StalledStdin.new)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @transport.stub(:write_timeout, 0.05) do
      refute @transport.write_message({ jsonrpc: "2.0", method: "ping", params: {} })
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0, "a full pipe must fail at the deadline, not park forever"
    assert_match(/write failed/, @transport.instance_variable_get(:@reader_failure))
  end

  # --- Issue #601: bounded Content-Length framing ----------------------------

  def assert_reader_failed_for_frame(frame, failure_pattern)
    @transport.instance_variable_set(:@running, true)
    @transport.start_reader_thread
    @transport.instance_variable_get(:@pending_requests)[1] = 0.0

    @from_server_w.write(frame)
    @from_server_w.close

    error = assert_raises(Rubik::LSP::Transport::RequestError) do
      @transport.wait_for_response(1, timeout: 2)
    end
    assert_equal :reader_failure, error.reason
    assert_match(failure_pattern, @transport.instance_variable_get(:@reader_failure))
    assert @transport.crashed?, "invalid framing must break the reader loop, not park it"
  end

  def test_non_positive_content_length_fails_reader
    assert_reader_failed_for_frame(
      "Content-Length: 0\r\n\r\n",
      /invalid Content-Length: 0/
    )
  end

  def test_oversized_content_length_fails_reader_instead_of_blocking
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_reader_failed_for_frame(
      "Content-Length: #{Rubik::LSP::Transport::MAX_FRAME_SIZE + 1}\r\n\r\n",
      /invalid Content-Length: #{Regexp.escape((Rubik::LSP::Transport::MAX_FRAME_SIZE + 1).to_s)}/
    )
    # The garbage header must fail fast, not park on an unbounded read.
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 2.0
  end

  def test_max_frame_size_boundary_payload_is_accepted
    @transport.instance_variable_set(:@running, true)
    @transport.start_reader_thread
    @transport.instance_variable_get(:@pending_requests)[7] = 0.0

    body = JSON.dump(jsonrpc: "2.0", id: 7, result: { "ok" => true })
    @from_server_w.write(framed(body))
    @from_server_w.close

    msg = @transport.wait_for_response(7, timeout: 2)
    assert_equal({ "ok" => true }, msg, "a legal frame must still correlate normally")
  end
end
