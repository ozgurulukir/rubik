# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

class TestLspIssue206Regressions < Minitest::Test
  class RestartableClient
    attr_reader :start_count, :running

    def initialize(start_ok: true)
      @start_ok = start_ok
      @running = false
      @start_count = 0
    end

    def available? = true
    def alive? = @running
    def language = "ruby"
    def server_cmd = "fake-lsp"

    def start
      @start_count += 1
      @running = @start_ok
      @start_ok
    end

    def stop
      @running = false
    end

    def hover(*)
      { ok: true, result: { "replacement" => true } }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rubik_lsp_issue_206")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_wait_for_response_distinguishes_null_timeout_and_reader_failure
    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp)
    client.instance_variable_get(:@pending_requests)[1] = 0.0
    client.instance_variable_get(:@responses)[1] = { "id" => 1, "result" => nil }
    assert_nil client.send(:wait_for_response, 1, timeout: 0.01), "JSON null is a completed response"

    timeout = assert_raises(Rubik::LSP::Client::RequestError) do
      client.send(:wait_for_response, 2, timeout: 0.01)
    end
    assert_equal :timeout, timeout.reason
    refute client.instance_variable_get(:@pending_requests).key?(2)

    client.instance_variable_set(:@reader_failure, "reader closed")
    reader_error = assert_raises(Rubik::LSP::Client::RequestError) do
      client.send(:wait_for_response, 3, timeout: 1)
    end
    assert_equal :reader_failure, reader_error.reason
    assert_equal "reader closed", reader_error.message
  end

  def test_hover_definition_and_references_keep_empty_success_separate_from_timeout
    client = live_client
    client.define_singleton_method(:send_request) { |*| nil }

    [:hover, :definition, :references].each do |operation|
      assert_equal({ ok: true, result: nil }, client.public_send(operation, "src/main.rb", 0, 0))
    end

    timeout = Rubik::LSP::Client::RequestError.new(:timeout, "LSP request timed out")
    client.define_singleton_method(:send_request) { |*| raise timeout }
    [:hover, :definition, :references].each do |operation|
      result = client.public_send(operation, "src/main.rb", 0, 0)
      assert_equal false, result[:ok]
      assert_includes result[:error], "timed out"
    end
  end

  def test_text_document_requests_and_notifications_use_one_canonical_uri
    client = live_client
    messages = []
    requests = []
    client.define_singleton_method(:write_message) { |message| messages << message }
    client.define_singleton_method(:send_request) do |method, params, **|
      requests << [method, params.dig(:textDocument, :uri)]
      nil
    end

    relative = File.join("src", "Example.rb")
    equivalent = if Rubik::Platform.windows?
                   File.join("src", "..", "src", "Example.rb").tr("/", "\\")
                 else
                   File.join("src", "..", "src", "Example.rb")
                 end
    absolute = File.join(@tmp, "src", "Example.rb")

    assert client.did_open(relative, "puts :ok")
    assert client.document_open?(absolute)
    assert client.did_change(absolute, "puts :changed")
    assert_equal({ ok: true, result: nil }, client.hover(equivalent, 0, 0))
    assert_equal({ ok: true, result: nil }, client.definition(absolute, 0, 0))
    assert_equal({ ok: true, result: nil }, client.references(relative, 0, 0))
    assert client.did_close(equivalent)

    notification_uris = messages.map { |message| message.dig(:params, :textDocument, :uri) }
    request_uris = requests.map(&:last)
    all_uris = notification_uris + request_uris
    assert_equal 6, all_uris.length
    assert_equal [all_uris.first], all_uris.uniq

    return unless Rubik::Platform.windows?

    client.hover(absolute.swapcase, 0, 0)
    assert_equal all_uris.first, requests.last.last
  end

  def test_server_requests_are_answered_before_client_response_correlation
    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp)
    messages = []
    client.define_singleton_method(:write_message) { |message| messages << message }
    client.instance_variable_get(:@pending_requests)[7] = 0.0

    client.send(:handle_incoming_message, {
                  "jsonrpc" => "2.0",
                  "id" => 7,
                  "method" => "workspace/configuration",
                  "params" => { "items" => [{ "section" => "ruby" }, { "section" => "rubik" }] }
                })

    assert_equal 7, messages.last[:id]
    assert_equal [{}, {}], messages.last[:result]
    refute client.instance_variable_get(:@responses).key?(7), "server request IDs must not satisfy client requests"

    client.send(:handle_incoming_message, { "jsonrpc" => "2.0", "id" => 8, "method" => "workspace/unknown" })
    assert_equal 8, messages.last[:id]
    assert_equal(-32_601, messages.last.dig(:error, :code))
    assert_includes messages.last.dig(:error, :message), "Method not found"

    client.send(:handle_incoming_message, { "jsonrpc" => "2.0", "id" => 7, "result" => nil })
    assert_nil client.send(:wait_for_response, 7, timeout: 0.01)
  end

  def test_client_for_replaces_dead_client_once_and_request_uses_replacement
    manager = lsp_manager
    stale = dead_client
    manager.clients["ruby"] = stale
    replacement = RestartableClient.new
    gate = Queue.new

    results = Rubik::LSP::Client.stub(:new, ->(*, **) { replacement }) do
      threads = 2.times.map do
        Thread.new do
          gate.pop
          manager.client_for("ruby")
        end
      end
      2.times { gate << true }
      threads.map(&:value)
    end

    assert_same replacement, results.first
    assert_same replacement, results.last
    assert_equal 1, replacement.start_count
    assert_empty manager.crash_stats, "successful recovery clears the consecutive-crash circuit"
    assert_equal({ ok: true, result: { "replacement" => true } }, manager.hover("main.rb", 0, 0))
  end

  def test_ensure_healthy_does_not_discard_another_callers_replacement
    manager = lsp_manager
    stale = dead_client
    manager.clients["ruby"] = stale
    replacement = RestartableClient.new
    gate = Queue.new

    results = Rubik::LSP::Client.stub(:new, ->(*, **) { replacement }) do
      threads = 2.times.map do
        Thread.new do
          gate.pop
          manager.ensure_healthy!(stale)
        end
      end
      2.times { gate << true }
      threads.map(&:value)
    end

    assert(results.all? { |client| client.equal?(replacement) })
    assert_equal 1, replacement.start_count
    assert_empty manager.crash_stats, "successful recovery clears the consecutive-crash circuit"
  end

  def test_failed_recovery_returns_a_specific_request_error
    manager = lsp_manager
    manager.clients["ruby"] = dead_client
    replacement = RestartableClient.new(start_ok: false)

    result = nil
    Rubik::LSP::Client.stub(:new, ->(*, **) { replacement }) do
      capture_io { result = manager.hover("main.rb", 0, 0) }
    end

    assert_equal false, result[:ok]
    assert_includes result[:error], "restart failed"
  end

  def test_reader_eof_marks_client_crashed_and_triggers_recovery_without_stacking_disposables
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::LSP::Manager.new(
      config: { "lsp.enabled" => true, "lsp.auto_start" => true, "lsp.servers.ruby" => nil },
      root_dir: @tmp,
      context: ctx
    )

    crashed = Rubik::LSP::Client.new("ruby", root_dir: @tmp)
    crashed.instance_variable_set(:@running, true)
    crashed.instance_variable_set(:@reader_alive, true)
    crashed.instance_variable_set(:@stdout, StringIO.new(""))
    crashed.instance_variable_set(:@stdin, StringIO.new)
    crashed.send(:start_reader_thread)
    crashed.instance_variable_get(:@reader_thr).join

    refute crashed.running
    assert crashed.crashed?, "unexpected reader EOF while running must mark client crashed"

    manager.clients["ruby"] = crashed
    replacement = RestartableClient.new
    Rubik::LSP::Client.stub(:new, ->(*, **) { replacement }) do
      assert_equal({ ok: true, result: { "replacement" => true } }, manager.hover("main.rb", 0, 0))
    end
    assert_same replacement, ctx.require("lsp:ruby")
    baseline_disposables = ctx.disposable_count

    # Simulate a second crash and recovery: context disposables must not grow unboundedly
    replacement_two = RestartableClient.new
    manager.clients["ruby"] = dead_client
    Rubik::LSP::Client.stub(:new, ->(*, **) { replacement_two }) do
      assert_equal({ ok: true, result: { "replacement" => true } }, manager.hover("main.rb", 0, 0))
    end
    assert_equal baseline_disposables, ctx.disposable_count

    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp)
    messages = []
    client.define_singleton_method(:write_message) { |message| messages << message }
    client.send(:handle_incoming_message, { "jsonrpc" => "2.0", "id" => 11, "method" => "client/registerCapability", "params" => {} })
    assert_equal 11, messages.last[:id]
    assert messages.last.key?(:result)
    assert_nil messages.last[:result]
  end

  private

  def live_client
    Rubik::LSP::Client.new("ruby", root_dir: @tmp).tap do |client|
      client.instance_variable_set(:@running, true)
      client.instance_variable_set(:@reader_alive, true)
    end
  end

  def dead_client
    Rubik::LSP::Client.new("ruby", root_dir: @tmp).tap do |client|
      client.instance_variable_set(:@running, true)
      client.define_singleton_method(:alive?) { false }
      client.define_singleton_method(:stop) { @running = false }
    end
  end

  def lsp_manager
    Rubik::LSP::Manager.new(
      config: { "lsp.enabled" => true, "lsp.auto_start" => true, "lsp.servers.ruby" => nil },
      root_dir: @tmp
    )
  end
end
