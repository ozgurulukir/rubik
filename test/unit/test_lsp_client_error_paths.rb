# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "open3"
require "minitest/mock"

# G13: LSP::Client error paths pinned against in-memory fakes — no language
# server process is spawned. Each test exercises a specific rescue arm so a
# refactor cannot silently turn a graceful degradation into a crash (or vice
# versa): start-failure, request-method failures reporting {ok: false},
# document notification failures reporting false, and reader-loop resilience
# to a transient (non-IO) error.
class TestLspClientErrorPaths < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_lsp_client_err")
    @client = Rubik::LSP::Client.new("ruby", root_dir: @tmp, server_cmd: "ruby --version")
  end

  def teardown
    @client.instance_variable_get(:@wait_thr)&.kill
    @client.instance_variable_get(:@wait_thr)&.join(0.1)
    @client.instance_variable_set(:@running, false)
    remove_temp_dir(@tmp) if File.directory?(@tmp)
  end

  # Gets raises once (transient internal error, NOT IOError) then hits EOF.
  class TransientErrorStdout
    def closed? = false

    def gets
      @calls ||= 0
      raise "boom" if (@calls += 1) == 1

      nil
    end
  end

  class FlushBoomStdin
    def closed? = false

    def write(*) = 1

    def flush
      raise IOError, "simulated flush failure"
    end
  end

  class WriteBoomStdin
    def closed? = false

    def write(*)
      raise IOError, "simulated write failure"
    end

    def flush; end
  end

  def test_start_returns_false_when_spawn_fails
    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp, server_cmd: RbConfig.ruby.to_s)
    assert client.available?, "precondition: interpreter must resolve so the spawn path is reached"

    Open3.stub(:popen3, ->(*) { raise Errno::ENOENT, "simulated spawn failure" }) do
      assert_equal false, client.start
    end
    refute client.running
  end

  def test_definition_references_hover_report_errors_without_raising
    fake_running_client!

    [:definition, :references, :hover].each do |m|
      res = @client.public_send(m, nil, 0, 0)
      refute res[:ok], "#{m} must fail soft on an unusable path"
      assert res[:error].is_a?(String) && !res[:error].empty?
    end
  end

  def test_did_open_and_did_change_report_false_on_failure
    fake_running_client!

    assert_equal false, @client.did_open(nil, "content")
    assert_equal false, @client.did_change(nil, "content")
  end

  def test_did_close_reports_false_on_failure
    fake_running_client!

    assert_equal false, @client.did_close(nil)
  end

  def test_document_open_handles_invalid_paths
    fake_running_client!

    assert_equal false, @client.document_open?(nil)
    assert_equal false, @client.document_open?("bad\u0000path")
  end

  def test_reader_loop_survives_a_transient_error_then_stops_at_eof
    @client.instance_variable_set(:@running, true)
    @client.instance_variable_set(:@reader_alive, true)
    @client.instance_variable_set(:@stdout, TransientErrorStdout.new)
    @client.instance_variable_set(:@stdin, StringIO.new)

    _, err = capture_io do
      @client.send(:start_reader_thread)
      @client.instance_variable_get(:@reader_thr).join
    end

    assert_includes err, "Reader loop error", "transient reader errors must stay visible via Rubik::Log"
    assert_equal false, @client.instance_variable_get(:@running), "reader ensure must stop the transport"
  end

  class MalformedJsonBodyStdout
    def closed? = false

    def gets
      @calls ||= 0
      @calls += 1
      case @calls
      when 1 then "Content-Length: 12\r\n"
      when 2 then "\r\n"
      end
    end

    def read(_len)
      return nil if @read_done

      @read_done = true
      "{bad_json_body"
    end
  end

  def test_reader_loop_handles_malformed_json_message_via_rubik_log
    @client.instance_variable_set(:@running, true)
    @client.instance_variable_set(:@reader_alive, true)
    @client.instance_variable_set(:@stdout, MalformedJsonBodyStdout.new)
    @client.instance_variable_set(:@stdin, StringIO.new)

    _, err = capture_io do
      @client.send(:start_reader_thread)
      @client.instance_variable_get(:@reader_thr).join
    end

    assert_includes err, "Failed to handle message", "JSON parse errors must be logged via Rubik::Log"
  end

  def test_did_open_reports_stdin_flush_failure_without_committing_document
    fake_running_client!
    @client.instance_variable_set(:@stdin, FlushBoomStdin.new)

    assert_equal false, @client.did_open(File.join(@tmp, "a.rb"), "puts 1")
    refute @client.document_open?(File.join(@tmp, "a.rb"))
  end

  def test_did_open_reports_stdin_write_failure_without_committing_document
    fake_running_client!
    @client.instance_variable_set(:@stdin, WriteBoomStdin.new)

    assert_equal false, @client.did_open(File.join(@tmp, "b.rb"), "puts 2")
    refute @client.document_open?(File.join(@tmp, "b.rb"))
  end

  def test_did_close_reports_stdin_write_failure_and_restores_full_document_state
    fake_running_client!
    path = File.join(@tmp, "close_boom.rb")
    assert @client.did_open(path, "puts :v1"), "precondition: open must succeed"
    publish_diagnostics(path, 1, [{ "severity" => 1, "message" => "stale error" }])
    assert @client.did_change(path, "puts :v2"), "precondition: change must succeed"

    @client.instance_variable_set(:@stdin, WriteBoomStdin.new)
    assert_equal false, @client.did_close(path)

    assert @client.document_open?(path), "a failed didClose must re-enter the document as open"
    snapshot = @client.diagnostics_snapshot_for(path)
    assert_equal :pending, snapshot[:state], "the diagnostic state captured before close must be restored"
    assert_equal 2, snapshot[:document_version], "the saved open version must be restored"
    assert_equal "stale error", @client.diagnostics_for(path).first["message"],
                 "the published diagnostics must be restored"

    # Re-arm the transport (the write failure disabled alive?): the
    # unchanged-content short-circuit proves the previous content survived.
    rearm_fake_transport!
    sends = []
    @client.define_singleton_method(:send_notification) do |method, _params|
      sends << method
      true
    end
    assert @client.did_change(path, "puts :v2"), "restored content must keep the document usable"
    assert_empty sends, "no didChange may be re-sent when the restored content matches"
  end

  def test_did_change_reports_stdin_write_failure_and_restores_previous_document_state
    fake_running_client!
    path = File.join(@tmp, "change_boom.rb")
    assert @client.did_open(path, "puts :v1"), "precondition: open must succeed"
    publish_diagnostics(path, 1, [{ "severity" => 1, "message" => "old error" }])

    @client.instance_variable_set(:@stdin, WriteBoomStdin.new)
    assert_equal false, @client.did_change(path, "puts :v2")

    snapshot = @client.diagnostics_snapshot_for(path)
    assert_equal 1, snapshot[:document_version], "a failed didChange must restore the previous open version"
    assert_equal :fresh, snapshot[:state], "the pre-change diagnostic state must be restored"
    assert_equal "old error", @client.diagnostics_for(path).first["message"],
                 "the published diagnostics must survive the rollback"

    # Re-arm the transport (the write failure disabled alive?): the
    # unchanged-content short-circuit proves the previous content survived.
    rearm_fake_transport!
    sends = []
    @client.define_singleton_method(:send_notification) do |method, _params|
      sends << method
      true
    end
    assert @client.did_change(path, "puts :v1"), "restored content must keep the document usable"
    assert_empty sends, "no didChange may be re-sent when the restored content matches"
  end

  def test_write_failure_wakes_a_pending_request_immediately
    @client.instance_variable_set(:@stdin, StringIO.new)
    @client.instance_variable_get(:@stdin).close

    error = assert_raises(Rubik::LSP::Client::RequestError) do
      @client.send(:send_request, "textDocument/hover", {}, timeout: 10)
    end

    assert_equal :transport_failure, error.reason
    assert_empty @client.instance_variable_get(:@pending_requests)
  end

  class CloseBoomIO < StringIO
    def close = raise IOError, "close boom"
  end

  # Dead wait-thread double: stop() skips its kill_tree branch when the
  # waiter reports dead (real popen3 waiters are Process::Waiter and answer
  # #pid; a plain Thread does not, so stop() must not reach that line here).
  class DeadWaiter
    def alive? = false

    def join(*) = nil

    def kill = nil
  end

  def test_stop_survives_io_close_failure
    fake_running_client!
    @client.instance_variable_set(:@wait_thr, DeadWaiter.new)
    @client.instance_variable_set(:@stdin, CloseBoomIO.new)

    @client.stop

    refute @client.running, "a failing io#close must not escape stop()"
  end

  # Injects a publishDiagnostics payload directly, as the reader thread
  # would (mirrors the sibling regression suites' publish helper).
  def publish_diagnostics(path, version, diagnostics)
    params = { "uri" => Rubik::Platform.to_file_uri(path), "diagnostics" => diagnostics, "version" => version }
    @client.send(:handle_incoming_message, { "method" => "textDocument/publishDiagnostics", "params" => params })
  end

  # A failed transport write marks the client crashed (@running = false in
  # write_message's rescue). Restore the alive? gate with a fresh in-memory
  # stdin so the post-rollback assertions can drive the document API again.
  def rearm_fake_transport!
    @client.instance_variable_set(:@running, true)
    @client.instance_variable_set(:@stdin, StringIO.new)
  end
end
