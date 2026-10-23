# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "minitest/mock"

class TestLspIssues245251Regressions < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik lsp issues ")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_structured_command_and_legacy_quoted_string_become_argv_without_shell
    structured = { "executable" => "/opt/Ruby SDK/bin/ruby", "args" => ["server file.rb", "value; $(literal)"] }
    assert_equal ["/opt/Ruby SDK/bin/ruby", "server file.rb", "value; $(literal)"],
                 Rubik::LSP::ServerCommand.argv(structured)
    assert_equal ["ruby", "server file.rb", "value; $(literal)"],
                 Rubik::LSP::ServerCommand.argv("ruby 'server file.rb' 'value; $(literal)'")
    assert_raises(ArgumentError) { Rubik::LSP::ServerCommand.argv("ruby 'unclosed") }
    assert_equal ["C:\\Program Files\\LSP\\server.exe", "--label", "argument with spaces", "literal; $(value)"],
                 Rubik::LSP::ServerCommand.send(
                   :split_windows,
                   '"C:\Program Files\LSP\server.exe" --label "argument with spaces" "literal; $(value)"'
                 )
  end

  def test_discovery_and_config_persistence_keep_structured_commands
    executable = spaced_ruby_executable
    command = { "executable" => executable, "args" => ["server with spaces.rb", "a; b"] }
    assert Rubik::Runtime::Discovery.binary_available?(command)
    assert_equal command, Rubik::Runtime::Discovery.probe_lsp("ruby", root_dir: @tmp, custom_cmd: command)

    home = Dir.mktmpdir("rubik config home ")
    config = Rubik::Config.new(root_dir: @tmp, home_dir: home)
    assert config.set("lsp.servers.ruby", command, persist: :project)[:ok]
    reloaded = Rubik::Config.new(root_dir: @tmp, home_dir: home)
    assert_equal command, reloaded.fetch("lsp.servers.ruby")
  ensure
    FileUtils.remove_entry(home) if home && File.directory?(home)
  end

  def test_structured_command_spawns_server_with_exact_argv_from_spaced_path
    script = File.join(@tmp, "fake LSP server.rb")
    argv_file = File.join(@tmp, "received argv.json")
    File.write(script, <<~'RUBY')
      require "json"
      File.write(ARGV.shift, JSON.dump(ARGV))
      loop do
        line = $stdin.gets or break
        length = line.split(":", 2).last.to_i
        $stdin.gets
        message = JSON.parse($stdin.read(length))
        if message["id"]
          result = message["method"] == "initialize" ? { capabilities: { textDocumentSync: { openClose: true, change: 1 } } } : nil
          body = JSON.dump(jsonrpc: "2.0", id: message["id"], result: result)
          $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          $stdout.flush
        end
        break if message["method"] == "exit"
      end
    RUBY
    arguments = ["argument with spaces", "literal; $(not executed)"]
    client = Rubik::LSP::Client.new(
      "custom", root_dir: @tmp,
      server_cmd: { "executable" => spaced_ruby_executable, "args" => [script, argv_file, *arguments] }
    )

    assert client.start
    wait_until { File.exist?(argv_file) }
    assert_equal arguments, JSON.parse(File.read(argv_file))
    client.stop
  end

  def test_server_sync_capabilities_control_notifications_and_reject_dynamic_registration
    none, none_log = start_fake_server(0)
    assert_equal 0, none.sync_capabilities[:change]
    refute none.did_open("none.rb", "x")
    refute none.did_change("none.rb", "y")
    refute messages_from(none_log).any? { |m| ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"].include?(m["method"]) }
    none.stop

    [1, 2].each do |kind|
      client, log = start_fake_server(kind)
      assert_equal kind, client.sync_capabilities[:change]
      assert client.did_open("sync.rb", "first")
      assert client.did_change("sync.rb", "second")
      assert client.did_close("sync.rb")
      messages = messages_from(log)
      changes = messages.select { |m| m["method"] == "textDocument/didChange" }
      assert_equal 1, changes.size
      assert_equal [{ "text" => "second" }], changes.first.dig("params", "contentChanges")
      assert_nil changes.first.dig("params", "contentChanges", 0, "range")

      client.send(:handle_server_request, {
                    "id" => 900 + kind,
                    "method" => "client/registerCapability",
                    "params" => { "registrations" => [{ "id" => "dynamic", "method" => "textDocument/definition" }] }
                  })
      wait_until { messages_from(log).any? { |m| m["id"] == 900 + kind } }
      registration_response = messages_from(log).find { |m| m["id"] == 900 + kind }
      assert_equal(-32_602, registration_response.dig("error", "code"))
      client.stop
    end
  end

  def test_sync_options_honor_open_close_change_save_and_advertised_client_contract
    client, log = start_fake_server(
      "openClose" => false,
      "change" => 0,
      "save" => { "includeText" => true }
    )
    init = messages_from(log).find { |m| m["method"] == "initialize" }
    caps = init.dig("params", "capabilities", "textDocument")
    refute caps.dig("definition", "dynamicRegistration")
    refute caps.dig("references", "dynamicRegistration")
    refute caps.dig("synchronization", "dynamicRegistration")
    assert caps.dig("synchronization", "didSave")
    refute client.did_open("options.rb", "content")
    refute client.did_change("options.rb", "updated")
    assert client.did_save("options.rb", "saved text")
    wait_until { messages_from(log).any? { |m| m["method"] == "textDocument/didSave" } }
    saved = messages_from(log).find { |m| m["method"] == "textDocument/didSave" }
    assert_equal "saved text", saved.dig("params", "text")
    client.stop
  end

  def test_document_sync_selects_language_id_independently_from_server_key
    capture = Class.new do
      attr_reader :opens, :language
      attr_accessor :running

      def initialize(language)
        @language = language
        @running = true
        @opens = []
      end

      def alive? = @running
      def crashed? = false
      def document_open?(_path) = false
      def did_open(path, content, language_id)
        @opens << [path, content, language_id]
        true
      end
    end
    manager = Rubik::LSP::Manager.new(config: { "lsp.enabled" => true }, root_dir: @tmp)
    clients = { "c" => capture.new("c"), "typescript" => capture.new("typescript"),
                "javascript" => capture.new("javascript"), "bash" => capture.new("bash") }
    manager.clients.merge!(clients)

    expected = {
      "a.c" => ["c", "c"], "a.cpp" => ["c", "cpp"], "a.hpp" => ["c", "cpp"],
      "a.ts" => ["typescript", "typescript"], "a.tsx" => ["typescript", "typescriptreact"],
      "a.js" => ["javascript", "javascript"], "a.jsx" => ["javascript", "javascriptreact"],
      "a.sh" => ["bash", "shellscript"]
    }
    expected.each do |path, (server_key, language_id)|
      assert manager.sync_buffer_file(path, "content")
      assert_equal language_id, clients.fetch(server_key).opens.last.last
    end
  end

  def test_canonical_diagnostics_are_unique_and_freshness_survives_edits
    client = live_client
    sent = []
    client.define_singleton_method(:send_notification) { |method, params| sent << [method, params]; true }
    path = File.join(@tmp, "src", "audit.rb")
    assert client.did_open(path, "v1")
    publish(client, path, 1, [{ "severity" => 1, "message" => "old error" }])
    assert_equal :fresh, client.diagnostics_snapshot_for("src/audit.rb")[:state]

    config = { "lsp.enabled" => true }
    def config.fetch(key, default = nil)
      self[key] || default
    end
    manager = Rubik::LSP::Manager.new(config: config, root_dir: @tmp)
    manager.clients["ruby"] = client
    workspace = Rubik::Tools::LSPDiagnosticsTool.new(manager).execute
    assert_includes workspace, "(1 issue(s))"
    assert_equal 1, workspace.scan(/^File:/).size
    status = manager.status_summary[:servers]["ruby"]
    assert_equal 1, status[:diagnostics_count]

    assert client.did_change(path, "v2")
    pending = client.diagnostics_snapshot_for("src/audit.rb")
    assert_equal :pending, pending[:state]
    assert_equal "old error", pending[:diagnostics].first["message"]
    publish(client, path, 1, [{ "severity" => 1, "message" => "obsolete error" }])
    assert_equal "old error", client.diagnostics_for(path).first["message"]

    publish(client, path, 2, [])
    assert_equal :fresh, client.diagnostics_snapshot_for(path)[:state]
    assert_empty client.diagnostics_for(path)
    assert_equal 1, client.all_diagnostics.size
    assert_equal 1, client.all_diagnostic_snapshots.size

    notifications_before = sent.size
    assert client.did_change(path, "v2")
    assert_equal notifications_before, sent.size, "unchanged contents must not resend or invalidate a completed snapshot"
    assert_equal :fresh, client.diagnostics_snapshot_for(path)[:state]

    assert client.did_change(path, "v3")
    publish(client, path, nil, [{ "severity" => 1, "message" => "unversioned error" }])
    snapshot = client.diagnostics_snapshot_for(path)
    assert_equal :unversioned, snapshot[:state]
    assert_equal "unversioned error", snapshot[:diagnostics].first["message"]
  end

  def test_concurrent_first_opens_serialize_document_state_and_frame_versions
    client = live_client
    entered = Queue.new
    release = Queue.new
    calls = []
    client.define_singleton_method(:send_notification) do |method, params|
      calls << [method, params]
      if method == "textDocument/didOpen"
        entered << true
        release.pop
      end
      true
    end

    first = Thread.new { client.did_open("race.rb", "v1") }
    entered.pop
    second = Thread.new { client.did_open("race.rb", "v2") }
    sleep 0.02
    refute second.join(0), "the second call waits for the first document transition"
    release << true

    assert first.value
    assert second.value
    assert_equal ["textDocument/didOpen", "textDocument/didChange"], calls.map(&:first)
    assert_equal [1, 2], calls.map { |(_, params)| params.dig(:textDocument, :version) }
  ensure
    release << true if release && release.empty?
    first&.kill&.join
    second&.kill&.join
  end

  def test_pending_diagnostics_tool_does_not_report_a_clean_file
    client = live_client
    client.define_singleton_method(:send_notification) { |*| true }
    client.did_open("pending.rb", "puts :pending")
    config = { "lsp.enabled" => true }
    manager = Rubik::LSP::Manager.new(config: config, root_dir: @tmp)
    manager.clients["ruby"] = client
    tool = Rubik::Tools::LSPDiagnosticsTool.new(manager)

    output = tool.execute("file_path" => "pending.rb")
    assert_includes output, "analysis is pending"
    refute_includes output, "all clean"
  end

  def test_crash_circuit_keeps_short_crash_history_then_resets_after_stability_or_cooldown
    manager = Rubik::LSP::Manager.new(
      config: { "lsp.enabled" => true, "lsp.auto_start" => true, "lsp.servers.ruby" => nil }, root_dir: @tmp
    )
    clock = 0.0
    clients = 2.times.map { Restartable.new }
    manager.stub(:monotonic_now, -> { clock }) do
      manager.clients["ruby"] = dead_restartable
      Rubik::LSP::Client.stub(:new, ->(*, **) { clients.shift || Restartable.new }) do
        first = manager.client_for("ruby")
        assert first.running
        assert_equal 1, manager.crash_stats.dig("ruby", :count)

        clock = 10.0
        first.crash!
        second = manager.client_for("ruby")
        assert second.running
        assert_equal 2, manager.crash_stats.dig("ruby", :count)

        clock = 20.0
        second.crash!
        assert_nil manager.client_for("ruby")
        assert_equal 3, manager.crash_stats.dig("ruby", :count)
        starts = first.start_count + second.start_count
        3.times { manager.client_for("ruby") }
        assert_equal starts, first.start_count + second.start_count

        clock = 321.0
        probe = manager.client_for("ruby")
        assert probe.running, "cooldown should allow one probe"
        clock = 382.0
        refute manager.circuit_open?("ruby")
        refute manager.crash_stats.key?("ruby"), "sustained health clears crash history"
      end
    end
  end

  private

  class Restartable
    attr_reader :start_count
    attr_accessor :running

    def initialize
      @running = false
      @start_count = 0
      @crashed = false
    end

    def available? = true
    def alive? = @running && !@crashed
    def crashed? = @crashed
    def language = "ruby"
    def server_cmd = "fake-lsp"

    def start
      @start_count += 1
      @running = true
      @crashed = false
      true
    end

    def crash!
      @crashed = true
    end

    def stop
      @running = false
    end
  end

  def dead_restartable
    Restartable.new.tap do |client|
      client.running = true
      client.crash!
    end
  end

  def live_client
    Rubik::LSP::Client.new("ruby", root_dir: @tmp).tap do |client|
      client.instance_variable_set(:@running, true)
      client.instance_variable_set(:@reader_alive, true)
      client.instance_variable_set(:@sync_capabilities, {
                                     source: :legacy_numeric, open_close: true, change: 2,
                                     save: true, include_text: true
                                   }.freeze)
    end
  end

  def publish(client, path, version, diagnostics)
    params = { "uri" => Rubik::Platform.to_file_uri(path), "diagnostics" => diagnostics }
    params["version"] = version unless version.nil?
    client.send(:handle_incoming_message, { "method" => "textDocument/publishDiagnostics", "params" => params })
  end

  def start_fake_server(capabilities)
    script = File.join(@tmp, "fake_sync_server.rb")
    log = File.join(@tmp, "messages-#{SecureRandom.hex(4)}.jsonl")
    File.write(script, <<~'RUBY')
      require "json"
      capabilities = JSON.parse(ARGV.fetch(0))
      log_path = ARGV.fetch(1)
      loop do
        line = $stdin.gets or break
        length = line.split(":", 2).last.to_i
        $stdin.gets
        message = JSON.parse($stdin.read(length))
        File.open(log_path, "a") { |file| file.puts(JSON.dump(message)) }
        next unless message["id"]
        result = if message["method"] == "initialize"
                   { capabilities: capabilities }
                 else
                   nil
                 end
        body = JSON.dump(jsonrpc: "2.0", id: message["id"], result: result)
        $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        $stdout.flush
        break if message["method"] == "exit"
      end
    RUBY
    command = [RbConfig.ruby, script, JSON.dump({ "textDocumentSync" => capabilities }), log]
    client = Rubik::LSP::Client.new("custom", root_dir: @tmp, server_cmd: command)
    assert client.start
    wait_until { File.exist?(log) }
    [client, log]
  end

  def messages_from(path)
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def spaced_ruby_executable
    return RbConfig.ruby if Rubik::Platform.windows?

    executable = File.join(@tmp, "ruby executable")
    unless File.exist?(executable)
      FileUtils.cp(RbConfig.ruby, executable)
      FileUtils.chmod(File.stat(RbConfig.ruby).mode, executable)
    end
    executable
  end
end
