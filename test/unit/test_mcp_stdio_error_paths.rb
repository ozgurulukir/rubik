# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# G13: MCP stdio transport error paths. All tests run against in-memory
# fakes or failing spawns — no real server process is ever started. Each
# test pins one failure contract: bad command syntax, spawn failure,
# closed/broken stdin, response timeout and protocol-level server errors.
class TestMcpStdioErrorPaths < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_mcp_stdio_err")
  end

  def teardown
    remove_temp_dir(@tmp) if File.directory?(@tmp)
  end

  # Fakes a live transport without spawning a process: running flag + a
  # StringIO stdin whose writes succeed, so send_request reaches the wait loop.
  def fake_running_transport(stdin = StringIO.new)
    t = Rubik::MCP::Transport::Stdio.new("noop", root_dir: @tmp)
    t.instance_variable_set(:@running, true)
    t.instance_variable_set(:@stdin, stdin)
    t.instance_variable_set(:@stdout, StringIO.new)
    t
  end

  class BrokenPipeStdin
    def closed? = false

    def close; end

    def puts(*) = raise Errno::EPIPE, "broken pipe"

    def flush; end
  end

  class EofOnGetsStdout
    def closed? = false

    def gets = raise IOError, "simulated stream close"
  end

  def test_unbalanced_quote_raises_connection_error
    t = Rubik::MCP::Transport::Stdio.new('rubik "unbalanced', root_dir: @tmp)

    e = assert_raises(Rubik::MCP::ConnectionError) { t.open }
    assert_includes e.message, "Invalid command syntax"
  end

  def test_spawn_failure_raises_connection_error
    guard = Rubik::Security::Guard.new
    guard.allowed_commands = ["definitely_not_a_real_binary_xyz"]
    t = Rubik::MCP::Transport::Stdio.new("definitely_not_a_real_binary_xyz", root_dir: @tmp, guard: guard)

    e = assert_raises(Rubik::MCP::ConnectionError) { t.open }
    assert_includes e.message, "Failed to spawn MCP process"
  end

  def test_closed_stdin_raises_connection_error
    t = fake_running_transport(StringIO.new.tap(&:close))

    e = assert_raises(Rubik::MCP::ConnectionError) { t.send_request("ping") }
    assert_includes e.message, "Process stdin is closed"
  end

  def test_broken_pipe_closes_transport_and_raises_connection_error
    t = fake_running_transport(BrokenPipeStdin.new)

    e = assert_raises(Rubik::MCP::ConnectionError) { t.send_request("ping") }
    assert_includes e.message, "Failed to write to MCP server"
    refute t.running?, "a broken pipe must tear the transport down"
  end

  def test_unanswered_request_raises_timeout_error
    t = fake_running_transport # no reader thread: the request is never answered

    assert_raises(Rubik::MCP::TimeoutError) { t.send_request("ping", {}, timeout: 0.15) }
  end

  def test_server_error_response_raises_protocol_error
    t = fake_running_transport
    t.instance_variable_get(:@responses)[1] = { "id" => 1, "error" => { "code" => -32_601, "message" => "Method not found" } }

    e = assert_raises(Rubik::MCP::ProtocolError) { t.send_request("tools/list", {}, timeout: 2) }
    assert_includes e.message, "Method not found"
    assert_includes e.message, "-32601"
  end

  def test_reader_stops_transport_when_stdout_closes
    t = Rubik::MCP::Transport::Stdio.new("noop", root_dir: @tmp)
    t.instance_variable_set(:@running, true)
    t.instance_variable_set(:@stdout, EofOnGetsStdout.new)

    t.send(:start_reader_thread)
    t.instance_variable_get(:@reader_thr).join

    refute t.running?, "reader ensure must mark the transport stopped on stream close"
  end

  class CloseBoomIO < StringIO
    def close = raise IOError, "close boom"
  end

  def test_close_survives_io_close_failure
    t = fake_running_transport(CloseBoomIO.new)

    t.close

    refute t.running?, "a failing io#close must not escape close()"
  end

  def test_late_response_does_not_accumulate_in_responses
    t = fake_running_transport
    assert_raises(Rubik::MCP::TimeoutError) do
      t.send_request("ping", {}, timeout: 0.05)
    end

    t.send(:handle_incoming_message, { "id" => 1, "result" => { "ok" => true } })

    assert_empty t.instance_variable_get(:@responses),
                 "late response arriving after timeout must not leak in @responses"
  end

  def test_late_reader_ensure_does_not_clobber_newer_incarnation
    t = Rubik::MCP::Transport::Stdio.new("noop", root_dir: @tmp)
    t.instance_variable_set(:@running, true)
    t.instance_variable_set(:@stdout, EofOnGetsStdout.new)

    t.instance_variable_set(:@generation, 1)
    t.send(:start_reader_thread)
    reader1 = t.instance_variable_get(:@reader_thr)

    t.instance_variable_get(:@mutex).synchronize do
      t.instance_variable_set(:@generation, 2)
      t.instance_variable_set(:@running, true)
    end

    reader1.join

    assert t.running?, "old reader ensure must not stop the fresh incarnation"
  end

  def test_close_spawns_reaper_for_lingering_child
    t = fake_running_transport
    fake_waiter = Object.new
    alive_calls = 0
    fake_waiter.define_singleton_method(:alive?) do
      alive_calls += 1
      alive_calls <= 2
    end
    fake_waiter.define_singleton_method(:pid) { 99_999 }
    fake_waiter.define_singleton_method(:join) { |_timeout| self }
    t.instance_variable_set(:@wait_thr, fake_waiter)

    Rubik::Platform.stub(:kill_tree, nil) do
      t.close
    end

    refute t.running?
    assert_nil t.instance_variable_get(:@wait_thr)
  end
end
