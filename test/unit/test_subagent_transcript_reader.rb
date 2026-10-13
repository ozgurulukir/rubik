# frozen_string_literal: true

require_relative "../test_helper"

# Issue #123: one canonical transcript interface. The reference resolves the
# EXECUTION (storage id) and then serves the right source — live memory while
# the run is active, the persisted JSONL snapshot once available — with
# snapshot-stable bounded pages, distinct pending/unknown/expired responses,
# and redaction parity between memory and disk.
class TestSubagentTranscriptReader < Minitest::Test
  Reader = Rubik::Orchestrator::Subagent::TranscriptReader

  def setup
    @ws_root = mint_test_root
    @outside = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = nil
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root && File.directory?(@ws_root)
    remove_temp_dir(@outside) if @outside && File.directory?(@outside)
  end

  def new_supervisor(provider: nil, config: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config
    )
  end

  def text_provider(content)
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    provider
  end

  def gate_provider
    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| gate.pop }
    [provider, gate]
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  def live_instance_with_seeded_history(prompt = "run the live probe")
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Live", prompt: prompt, max_steps: 3)
    assert(wait_until { inst.state == :running && !inst.history.empty? }, "the run must seed its live history")
    [sup, inst, gate]
  end

  def reader_tool(root = @outside)
    Rubik::Tools::ReadFileTool.new(Rubik::Buffer::Manager.new(root_dir: root), runtime_context: @root_context)
  end

  # ------------------------------------------------------- live before save

  def test_status_reference_serves_live_messages_before_the_first_save
    sup, inst, gate = live_instance_with_seeded_history("explore the live plane")
    refute File.exist?(inst.transcript_uri), "precondition: the durable save has not happened yet"
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, sup)

    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup, runtime_context: @root_context)
    data = JSON.parse(tool.execute("action" => "status", "conversation_id" => inst.id))
    assert_equal inst.transcript_ref, data["transcript_ref"], "status advertises the canonical reference"
    assert_equal "rubik://subagent/#{inst.storage_id}/transcript", data["transcript_ref"]

    # A different workspace root than the supervisor's: the live read must not
    # need any path allowlisting or root alignment.
    page = reader_tool.execute("path" => data["transcript_ref"])
    assert_kind_of String, page
    assert_includes page, "source=live", "before the first save the reference serves the live snapshot"
    assert_includes page, "explore the live plane", "live messages are readable immediately"
    assert_includes page, "[assembled system prompt omitted] prompt_sha256=",
                    "live serialization honors the same assembled-prompt stub as the durable copy"
    assert_includes page, "persisted=false", "the reader discloses that no durable file exists yet"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_spawn_response_advertises_the_canonical_reference
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup, runtime_context: @root_context)

    out = tool.execute("role" => "Scout", "prompt" => "probe")

    inst = sup.instances.values.first
    assert_includes out, "transcript: #{inst.transcript_ref}", "the spawn response carries the canonical reference"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  # ------------------------------------------------ pending / unknown / ...

  def test_tool_transcript_ids_cannot_traverse_outside_the_transcript_root
    FileUtils.mkdir_p(File.join(@ws_root, ".rubik", "subagents"))
    outside_path = File.join(@outside, "transcript.jsonl")
    File.write(outside_path, "PRIVATE OUTSIDE TRANSCRIPT")
    traversal = "../../../#{File.basename(@outside)}"
    assert_equal outside_path, File.expand_path(
      Rubik::Orchestrator::Subagent::TranscriptFormatter.transcript_path_for(@ws_root, traversal)
    ), "the fixture must target an existing file outside the workspace"

    page = Reader.read(storage_id: traversal, root_dir: @ws_root)
    refute page.ok?
    assert_equal :invalid, page.reason
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: new_supervisor, runtime_context: @root_context)
    output = tool.execute("action" => "transcript", "conversation_id" => traversal)
    assert output.error?
    assert_includes output.to_s, "Invalid subagent storage id"
    refute_includes output.to_s, "PRIVATE OUTSIDE TRANSCRIPT"
  end

  def test_pending_unknown_and_expired_are_distinct_responses
    pending_instance = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-p", parent_id: "agent-0", role: "Pending", type_name: "research",
      prompt: "p", context: @root_context, tool_registry: nil, root_dir: @ws_root
    )

    pending = Reader.read(storage_id: pending_instance.storage_id, instance: pending_instance, root_dir: @ws_root)
    refute pending.ok?
    assert_equal :pending, pending.reason
    assert_includes pending.message, "no transcript messages yet"

    unknown = Reader.read(storage_id: "ghost-sid", root_dir: @ws_root)
    refute unknown.ok?
    assert_equal :unknown, unknown.reason
    assert_includes unknown.message, "No execution or transcript found"
    assert_includes unknown.message, "Hint: for a running subagent the live copy is manage_subagents"

    expired = Reader.read(storage_id: "reaped-sid", root_dir: @ws_root, tracked: true)
    refute expired.ok?
    assert_equal :expired, expired.reason
    assert_includes expired.message, "no longer retained"
  end

  def test_persistence_failure_is_explicit_when_the_snapshot_is_unreadable
    path = Rubik::Orchestrator::Subagent::TranscriptFormatter.transcript_path_for(@ws_root, "sid-broken")
    FileUtils.mkdir_p(path) # a directory where the file belongs: File.read raises

    out = Reader.read(storage_id: "sid-broken", root_dir: @ws_root)
    refute out.ok?
    assert_equal :persistence_failure, out.reason
    assert_includes out.message, "could not be read"
  end

  # -------------------------------------------------- snapshot + pagination

  def test_disk_pages_belong_to_one_snapshot_and_reconstruct_the_file
    path = Rubik::Orchestrator::Subagent::TranscriptFormatter.transcript_path_for(@ws_root, "sid-disk")
    FileUtils.mkdir_p(File.dirname(path))
    body = "#{(1..60).map { |i| "{\"line\":#{i}}" }.join("\n")}\n"
    File.write(path, body)

    pages = []
    cursor = 0
    snapshot = nil
    loop do
      page = Reader.read(storage_id: "sid-disk", root_dir: @ws_root, cursor: cursor, limit: 40, snapshot: snapshot)
      assert page.ok?
      snapshot ||= page.snapshot
      assert_equal snapshot, page.snapshot, "every page reports the snapshot it belongs to"
      assert_equal "disk", page.source
      pages << page.body
      break unless page.has_more

      cursor = page.next_cursor
    end

    assert_equal body, pages.join, "pages reconstruct the persisted snapshot exactly"

    stale = Reader.read(storage_id: "sid-disk", root_dir: @ws_root, snapshot: "disk:0000000000000000")
    refute stale.ok?
    assert_equal :snapshot_changed, stale.reason
    assert_includes stale.message, "Start a new read at cursor 0"
  end

  def test_uri_fragment_continues_the_same_snapshot_page_sequence
    path = Rubik::Orchestrator::Subagent::TranscriptFormatter.transcript_path_for(@ws_root, "sid-uri")
    FileUtils.mkdir_p(File.dirname(path))
    body = "#{(1..40).map { |i| "{\"row\":#{i}}" }.join("\n")}\n"
    File.write(path, body)

    ref = Rubik::Uris.subagent_transcript("sid-uri")
    first = reader_tool(@ws_root).execute("path" => "#{ref}#limit=200")
    assert_includes first, "has_more=true"
    assert_includes first, "[next] read_file(path: '#{ref}#cursor=", "the footer carries the pinned continuation"

    snapshot = first[/snapshot=(\S+)/, 1]
    next_ref = first[/\[next\] read_file\(path: '([^']+)'\)/, 1]
    second = reader_tool(@ws_root).execute("path" => next_ref)
    assert_kind_of String, second
    assert_includes second, "has_more=false"
    assert_includes second, "snapshot=#{snapshot}", "the continuation stays on the pinned snapshot"
  end

  def test_live_snapshot_change_between_pages_is_not_silently_mixed
    sup, inst, gate = live_instance_with_seeded_history("first task body")
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, sup)

    first = sup.read_transcript(inst.storage_id, limit: 40)
    assert first.ok?
    assert_equal "live", first.source

    # The worker appends a message between pages: the snapshot token must change
    # and the stale continuation must answer explicitly instead of mixing or
    # duplicating records.
    inst.history << { role: "user", content: "[Message from maestro]: late steering" }
    stale = sup.read_transcript(inst.storage_id, cursor: first.next_cursor, limit: 40, snapshot: first.snapshot)
    refute stale.ok?
    assert_equal :snapshot_changed, stale.reason

    fresh = sup.read_transcript(inst.storage_id, limit: 40)
    assert fresh.ok?
    refute_equal first.snapshot, fresh.snapshot, "a fresh read observes the new snapshot"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  # -------------------------------------------------- concurrent-read safety

  def test_concurrent_reads_never_mix_snapshots
    sup, inst, gate = live_instance_with_seeded_history("concurrent probe")
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, sup)

    results = Queue.new
    readers = 4.times.map do
      Thread.new do
        cursor = 0
        snapshot = nil
        text = +""
        outcome = :ok
        30.times do
          page = sup.read_transcript(inst.storage_id, cursor: cursor, limit: 20, snapshot: snapshot)
          unless page.ok?
            outcome = page.reason == :snapshot_changed ? :changed : page.reason
            break
          end

          snapshot ||= page.snapshot
          text << page.body
          break unless page.has_more

          cursor = page.next_cursor
        end
        results << [outcome, snapshot, text]
      end
    end

    writer = Thread.new do
      5.times do
        inst.history << { role: "user", content: "[steering] churn" }
        sleep 0.002
      end
    end
    readers.each(&:join)
    writer.join

    assert_equal 4, results.size
    until results.empty?
      outcome, snapshot, text = results.pop
      assert_includes [:ok, :changed], outcome, "a concurrent read completes a snapshot or reports the change"
      next unless outcome == :ok

      assert_equal snapshot.split(":", 2).last, Digest::SHA256.hexdigest(text)[0, 16],
                   "a completed concurrent read reconstructs exactly its pinned snapshot (no mixed records)"
    end
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  # ------------------------------------------- redaction + retention parity

  def test_live_and_disk_redaction_are_identical
    token = "ghp_#{'c' * 36}"
    provider, gate = gate_provider
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Leaky", prompt: "use #{token} carefully", max_steps: 2)
    assert(wait_until { inst.state == :running && !inst.history.empty? })
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, sup)

    live = sup.read_transcript(inst.storage_id, limit: 100_000)
    assert live.ok?
    refute_includes live.body, token, "live reads are redacted like the durable copy"
    assert_includes live.body, Rubik::Security::Redactor::MASK_STRING

    gate << Struct.new(:content, :tool_calls).new("done #{token}", [])
    assert(wait_until { inst.terminal_and_settled? && File.exist?(inst.transcript_uri) })

    disk = sup.read_transcript(inst.storage_id, limit: 100_000)
    assert disk.ok?
    assert_equal "disk", disk.source, "a settled run reads the persisted snapshot"
    refute_includes disk.body, token
    assert_includes disk.body, Rubik::Security::Redactor::MASK_STRING
  end

  def test_persisted_reads_survive_reaping_and_expire_explicitly
    sup = new_supervisor(provider: text_provider("reap me"))
    inst = sup.spawn(role: "Reapable", prompt: "finish", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? && File.exist?(inst.transcript_uri) })

    assert_equal [inst.id], sup.reap_finished!(force: true)
    after_reap = sup.read_transcript(inst.storage_id)
    assert after_reap.ok?
    assert_equal "disk", after_reap.source, "the persisted snapshot survives reaping"
    assert_includes after_reap.body, "finish"

    File.delete(inst.transcript_uri)
    gone = sup.read_transcript(inst.storage_id)
    refute gone.ok?
    assert_equal :expired, gone.reason, "a tracked execution without content is expired, not unknown"
  end

  def test_transcript_action_serves_pages_and_survives_tombstone_eviction
    sup = new_supervisor(provider: text_provider("action body"), config: { "subagents.tombstone_limit" => 0 })
    inst = sup.spawn(role: "Actionable", prompt: "action probe", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? && File.exist?(inst.transcript_uri) })
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup, runtime_context: @root_context)

    res = tool.execute("action" => "transcript", "conversation_id" => inst.id)
    assert_includes res, "[transcript] execution=#{inst.storage_id}"
    assert_includes res, "source=disk"

    assert_equal [inst.id], sup.reap_finished!(force: true)
    assert_nil sup.get(inst.id), "precondition: the roster forgot the execution"
    raw = tool.execute("action" => "transcript", "conversation_id" => inst.storage_id)
    assert_includes raw, "action body", "the raw storage id stays addressable after eviction"

    ghost = tool.execute("action" => "transcript", "conversation_id" => "ghost-1")
    assert ghost.error?
    assert_includes ghost.to_s, "No execution or transcript found"
  end
end
