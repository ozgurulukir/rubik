# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "securerandom"

# Issue #583: two long-standing LSP contract gaps.
#
# 1. Pull diagnostics. Servers advertising `diagnosticProvider` (typeprof —
#    the DEFAULT ruby server — or ruby-lsp) never push
#    textDocument/publishDiagnostics; the client must send an explicit
#    textDocument/diagnostic request after didOpen/didChange or every
#    snapshot stays :pending forever.
# 2. Ranged didChange. Under Incremental sync (kind 2, spec 3.17) a
#    range-less contentChange is INVALID: spec-strict servers drop it, so
#    edits after the first never reach the server. Incremental must carry
#    one edit spanning the entire old document; Full sync (kind 1) keeps
#    the range-less whole-document form.
#
# The fake server harness below is the same pattern as
# test_lsp_issues_245_251_regressions.rb (real transport, real reader
# thread, JSONL message log) extended to answer textDocument/diagnostic
# with a scripted payload, so both the outgoing shape and the recorded
# store state are asserted end-to-end.
class TestLspPullDiagnosticsAndIncrementalSync < Minitest::Test
  DIAGNOSTIC_ITEM = {
    "range" => { "start" => { "line" => 1, "character" => 0 }, "end" => { "line" => 1, "character" => 4 } },
    "severity" => 1,
    "message" => "pulled issue"
  }.freeze
  RELATED_DIAGNOSTIC_ITEM = {
    "range" => { "start" => { "line" => 3, "character" => 2 }, "end" => { "line" => 3, "character" => 9 } },
    "severity" => 2,
    "message" => "related issue"
  }.freeze

  def setup
    @tmp = Dir.mktmpdir("rubik lsp 583 ")
    @clients = []
  end

  def teardown
    @clients.each(&:stop)
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  # --- Fix 2: sync-kind-aware didChange -----------------------------------

  def test_incremental_sync_sends_single_full_span_ranged_edit
    client, log = start_fake_server("textDocumentSync" => 2)
    assert_equal 2, client.sync_capabilities[:change]

    assert client.did_open("doc.rb", "line one\nline two\n")
    assert client.did_change("doc.rb", "brand new content")
    wait_until do
      changes = messages_from(log).select { |m| m["method"] == "textDocument/didChange" }
      changes.size == 1
    end
    edit = messages_from(log).find { |m| m["method"] == "textDocument/didChange" }
                             .dig("params", "contentChanges", 0)
    # ONE edit spanning the ENTIRE old document, with the new text.
    assert_equal({ "line" => 0, "character" => 0 }, edit["range"]["start"])
    assert_equal({ "line" => 2, "character" => 0 }, edit["range"]["end"])
    assert_equal "brand new content", edit["text"]
    assert_equal 2, edit.size, "incremental edit must carry exactly range + text"
  end

  def test_full_sync_keeps_range_less_whole_document_change
    client, log = start_fake_server("textDocumentSync" => 1)
    assert_equal 1, client.sync_capabilities[:change]

    assert client.did_open("doc.rb", "first")
    assert client.did_change("doc.rb", "second")
    wait_until do
      messages_from(log).any? { |m| m["method"] == "textDocument/didChange" }
    end
    change = messages_from(log).find { |m| m["method"] == "textDocument/didChange" }
    assert_equal [{ "text" => "second" }], change.dig("params", "contentChanges")
  end

  def test_incremental_ranged_edit_uses_utf16_code_units_for_multibyte_content
    client, log = start_fake_server("textDocumentSync" => 2)
    # "héllo" is one UTF-8 code point beyond ASCII but one UTF-16 unit;
    # "🀄" is astral-plane and encodes as TWO UTF-16 code units.
    old = "héllo🀄"
    assert client.did_open("doc.rb", old)
    assert client.did_change("doc.rb", "x")
    wait_until do
      messages_from(log).any? { |m| m["method"] == "textDocument/didChange" }
    end
    edit = messages_from(log).find { |m| m["method"] == "textDocument/didChange" }
                             .dig("params", "contentChanges", 0)
    assert_equal({ "line" => 0, "character" => 0 }, edit["range"]["start"])
    assert_equal({ "line" => 0, "character" => 7 }, edit["range"]["end"])
  end

  def test_incremental_ranged_edit_on_empty_content_does_not_produce_negative_line
    client, log = start_fake_server("textDocumentSync" => 2)
    assert client.did_open("empty.rb", "")
    assert client.did_change("empty.rb", "initial content")
    wait_until do
      messages_from(log).any? { |m| m["method"] == "textDocument/didChange" }
    end
    edit = messages_from(log).find { |m| m["method"] == "textDocument/didChange" }
                             .dig("params", "contentChanges", 0)
    # Empty old content must end at line 0 character 0, never negative line index.
    assert_equal({ "line" => 0, "character" => 0 }, edit["range"]["start"])
    assert_equal({ "line" => 0, "character" => 0 }, edit["range"]["end"])
    assert_equal "initial content", edit["text"]
  end

  def test_utf16_length_handles_invalid_byte_sequences_safely
    client, _log = start_fake_server("textDocumentSync" => 2)
    invalid_seq = [0xFF, 0xFE, 0xFD].pack("C*")
    # Must not raise ArgumentError: invalid byte sequence in UTF-8
    len = client.send(:utf16_length, invalid_seq)
    assert len.is_a?(Integer)
    assert len.positive?
  end

  # --- Fix 1: pull diagnostics ----------------------------------------------

  def test_diagnostic_provider_capabilities_enable_pull_and_record_items
    client, log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => { "interFileDependencies" => false, "workspaceDiagnostics" => false }
    )
    assert client.did_open("doc.rb", "content")
    wait_until do
      messages_from(log).any? { |m| m["method"] == "textDocument/diagnostic" }
    end
    pull = messages_from(log).find { |m| m["method"] == "textDocument/diagnostic" }
    refute_nil pull, "didOpen must trigger a textDocument/diagnostic pull"
    assert_equal client.send(:document_uri, "doc.rb"),
                 pull.dig("params", "textDocument", "uri")

    # The fake server answers with kind: full + items; the store must
    # record them at the document's current version.
    script_pull_response(client, "doc.rb", DIAGNOSTIC_ITEM)
    snapshot = wait_until { client.diagnostics_snapshot_for("doc.rb") }
    assert_equal :fresh, snapshot[:state]
    assert_equal 1, snapshot[:diagnostics].size
    assert_equal "pulled issue", snapshot[:diagnostics].first["message"]
  end

  def test_stale_versioned_pull_result_is_ignored
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "v1")
    version1 = client.instance_variable_get(:@document_store).version_for("doc.rb")

    # Server answers the pull for v1 only AFTER the document moved to v2:
    # the stale result must not clobber the newer state.
    client.did_change("doc.rb", "v2")
    client.send(:apply_pull_diagnostics_result, "doc.rb", version1, { "kind" => "full", "items" => [DIAGNOSTIC_ITEM] })

    snapshot = client.diagnostics_snapshot_for("doc.rb")
    refute_equal :fresh, snapshot[:state]
    assert_empty snapshot[:diagnostics]
  end

  def test_pull_diagnostics_unchanged_report_transitions_pending_to_fresh
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "v1")
    # First pull delivers an item
    script_pull_response(client, "doc.rb", DIAGNOSTIC_ITEM)
    snapshot1 = client.diagnostics_snapshot_for("doc.rb")
    assert_equal :fresh, snapshot1[:state]
    assert_equal 1, snapshot1[:diagnostics].size

    # did_change sets state back to :pending
    assert client.did_change("doc.rb", "v2")
    abs = client.send(:normalized_document_path, "doc.rb")
    version2 = client.instance_variable_get(:@document_store).version_for(abs)
    # Server returns unchanged: previous diagnostics remain valid
    client.send(:apply_pull_diagnostics_result, abs, version2, { "kind" => "unchanged" })
    snapshot2 = client.diagnostics_snapshot_for("doc.rb")
    assert_equal :fresh, snapshot2[:state]
    assert_equal 1, snapshot2[:diagnostics].size
  end

  def test_client_stop_and_start_clear_pull_in_flight_registry
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    abs = client.send(:normalized_document_path, "doc.rb")
    client.instance_variable_get(:@pull_mutex).synchronize do
      client.instance_variable_get(:@pull_in_flight)[abs] = 99
    end
    assert_equal 99, client.instance_variable_get(:@pull_in_flight)[abs]

    client.stop
    assert_empty client.instance_variable_get(:@pull_in_flight)
  end

  def test_push_only_server_never_pulls_and_push_still_records
    client, log = start_fake_server("textDocumentSync" => 1)
    assert client.did_open("doc.rb", "content")

    deliver_push(client, "doc.rb", [DIAGNOSTIC_ITEM])
    wait_until { client.diagnostics_snapshot_for("doc.rb")[:state] != :pending }
    snapshot = client.diagnostics_snapshot_for("doc.rb")
    assert_equal 1, snapshot[:diagnostics].size

    # No pull machinery may fire on a push-only server.
    refute_includes(messages_from(log).map { |m| m["method"] }, "textDocument/diagnostic")
  end

  # --- Issue #585: relatedDocuments -----------------------------------------

  def test_related_documents_are_recorded_through_version_guarded_path
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "content")
    assert client.did_open("other.rb", "other content")

    related = RELATED_DIAGNOSTIC_ITEM
    abs_other = client.send(:normalized_document_path, "other.rb")
    version = client.instance_variable_get(:@document_store).version_for(abs_other)
    client.send(:apply_pull_diagnostics_result,
                client.send(:normalized_document_path, "doc.rb"),
                client.instance_variable_get(:@document_store).version_for(client.send(:normalized_document_path, "doc.rb")),
                { "kind" => "full", "items" => [DIAGNOSTIC_ITEM],
                  "relatedDocuments" => {
                    client.send(:document_uri, "other.rb") => { "kind" => "full", "items" => [related] }
                  } })

    snapshot = client.diagnostics_snapshot_for("other.rb")
    assert_equal :fresh, snapshot[:state], "related document snapshot must go fresh"
    assert_equal 1, snapshot[:diagnostics].size
    assert_equal "related issue", snapshot[:diagnostics].first["message"]
    assert_equal version, snapshot[:published_version]
  end

  def test_related_documents_stale_version_is_discarded
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "content")
    assert client.did_open("other.rb", "v1")
    abs_doc = client.send(:normalized_document_path, "doc.rb")
    stale_version = client.instance_variable_get(:@document_store).version_for(abs_doc)

    # The pulled document moves to a new version before the pull result
    # lands: the WHOLE result — items AND relatedDocuments — must be
    # discarded by the outer version guard, leaving the related document
    # untouched (:pending, since nothing else was recorded for it).
    client.did_change("doc.rb", "v2")
    client.send(:apply_pull_diagnostics_result,
                abs_doc,
                stale_version,
                { "kind" => "full", "items" => [DIAGNOSTIC_ITEM],
                  "relatedDocuments" => {
                    client.send(:document_uri, "other.rb") => { "kind" => "full", "items" => [RELATED_DIAGNOSTIC_ITEM] }
                  } })

    snapshot = client.diagnostics_snapshot_for("doc.rb")
    refute_equal :fresh, snapshot[:state], "stale pull result must not record items"
    assert_empty snapshot[:diagnostics]
    related_snapshot = client.diagnostics_snapshot_for(client.send(:normalized_document_path, "other.rb"))
    assert_equal :pending, related_snapshot[:state], "related payload rides the same version guard"
    assert_empty related_snapshot[:diagnostics]
  end

  def test_related_documents_unknown_or_closed_uris_are_skipped
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "content")

    # Never-opened document URI plus a malformed URI: both must be skipped
    # without raising, and the pulled document must still be recorded.
    client.send(:apply_pull_diagnostics_result,
                client.send(:normalized_document_path, "doc.rb"),
                client.instance_variable_get(:@document_store).version_for(client.send(:normalized_document_path, "doc.rb")),
                { "kind" => "full", "items" => [DIAGNOSTIC_ITEM],
                  "relatedDocuments" => {
                    "file:///tmp/rubik-never-opened-#{SecureRandom.hex(4)}.rb" => { "kind" => "full", "items" => [RELATED_DIAGNOSTIC_ITEM] },
                    "not-a-uri" => { "kind" => "full", "items" => [] },
                    "file:///collected/garbage" => "not-a-hash"
                  } })

    snapshot = client.diagnostics_snapshot_for("doc.rb")
    assert_equal :fresh, snapshot[:state]
    assert_equal 1, snapshot[:diagnostics].size
  end

  # --- Tool surface ---------------------------------------------------------

  def test_lsp_diagnostics_tool_triggers_pull_refresh_and_surfaces_items
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "content")

    config = Rubik::Config.new(root_dir: @tmp)
    config.set("lsp.feedback_timeout", 1.0)
    manager = Rubik::LSP::Manager.new(root_dir: @tmp, config: config)
    manager.instance_variable_get(:@clients)["ruby"] = client

    # Fake-server pull answers flow through the transport; pre-seed the
    # response so the tool's bounded wait observes :fresh.
    script_pull_response(client, "doc.rb", DIAGNOSTIC_ITEM)

    tool = Rubik::Tools::LSPDiagnosticsTool.new(manager)
    out = tool.execute({})
    assert_includes out, "pulled issue"
  end

  def test_manager_refresh_pending_snapshots_pulls_pending_documents
    client, _log = start_fake_server(
      "textDocumentSync" => 1,
      "diagnosticProvider" => true
    )
    assert client.did_open("doc.rb", "content")
    manager = Rubik::LSP::Manager.new(root_dir: @tmp, config: Rubik::Config.new(root_dir: @tmp))
    manager.instance_variable_get(:@clients)["ruby"] = client

    manager.refresh_pending_diagnostic_snapshots
    script_pull_response(client, "doc.rb", DIAGNOSTIC_ITEM)
    snapshot = wait_until { client.diagnostics_snapshot_for("doc.rb") }
    assert_equal 1, snapshot[:diagnostics].size
  end

  private

  def deliver_push(client, path, diagnostics)
    client.send(:handle_incoming_message, {
                  "method" => "textDocument/publishDiagnostics",
                  "params" => {
                    "uri" => client.send(:document_uri, path),
                    "diagnostics" => diagnostics
                  }
                })
  end

  # Seeds a pull response without touching the transport's real wire:
  # records items directly via the same guarded path a real response takes.
  def script_pull_response(client, path, item)
    abs = client.send(:normalized_document_path, path)
    version = client.instance_variable_get(:@document_store).version_for(abs)
    client.send(:apply_pull_diagnostics_result, abs, version, { "kind" => "full", "items" => [item] })
  end

  # Real-transport fake server (same pattern as the 245/251 regressions
  # file): logs every incoming message to JSONL and answers requests with
  # nil unless a block scripts the result. Pulls time out harmlessly.
  def start_fake_server(capabilities)
    script = File.join(@tmp, "fake_583_server.rb")
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
    command = [RbConfig.ruby, script, JSON.dump(capabilities), log]
    client = Rubik::LSP::Client.new("ruby", root_dir: @tmp, server_cmd: command)
    (@clients ||= []) << client
    assert client.start, "fake server answers initialize; client.start must succeed"
    wait_until { File.exist?(log) }
    [client, log]
  end

  def messages_from(path)
    File.readlines(path).map { |line| JSON.parse(line) }
  end
end
