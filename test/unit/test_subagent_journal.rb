# frozen_string_literal: true

require_relative "../test_helper"

# Issue #124: the append-only execution journal — lifecycle, tool-call,
# tool-result and compaction events recorded before history pruning, never
# rewritten by compaction, redacted before persistence, bounded per file, and
# tolerant of an interrupted final write.
class TestSubagentJournal < Minitest::Test
  Journal = Rubik::Orchestrator::Subagent::Journal

  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = nil
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root && File.directory?(@ws_root)
  end

  def journal_path(name = "unit")
    File.join(@ws_root, "journals", "#{name}.jsonl")
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  def new_supervisor(provider:, registry: nil, buffer_manager: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, tool_registry: registry, buffer_manager: buffer_manager
    )
  end

  def text_provider(content)
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_hist, _opts = {}| resp }
    provider
  end

  # ---------------------------------------------------------- record shape

  def test_records_are_sequenced_typed_and_redacted_before_persistence
    path = journal_path("unit")
    journal = Journal.new(path: path)
    token = "ghp_#{'d' * 36}"

    journal.record_run_started(run: 1, role: "Scout", type: "research", prompt: "inspect #{token}")
    journal.record_tool_call(run: 1, call_id: "c1", tool: "run_command",
                             args: { "command" => "deploy #{token} now", "api_key" => "topsecret-value" })

    read = Journal.read(path)
    assert_equal 2, read.records.size
    assert_equal 0, read.skipped
    refute read.truncated

    first = read.records.first
    assert_equal [1, 1, "run_started"], [first["seq"], first["run"], first["event"]]
    refute_nil first["ts"], "records carry a timestamp"
    assert_includes first["data"]["prompt_preview"], "inspect"

    serialized = Rubik::Platform.safe_json_generate(read.records)
    refute_includes serialized, token, "credentials are redacted before persistence, never after"
    refute_includes serialized, "topsecret-value"
    assert_includes serialized, Rubik::Security::Redactor::MASK_STRING

    call = read.records.last
    assert_equal "c1", call["call_id"], "tool calls correlate by call id"
    assert_equal "run_command", call["data"]["tool"]
  end

  def test_redaction_precedes_preview_clipping
    journal = Journal.new(path: File.join(@ws_root, "boundary-journal.jsonl"))
    token = "ghp_#{'a' * 36}"
    journal.record_tool_result(run: 1, call_id: "boundary", tool: "read_file", status: :ok,
                               duration_ms: 1, output: "#{'x' * (Journal::PREVIEW_CHARS - 10)}#{token}tail")
    journal.record_tool_call(run: 1, call_id: "secret-key", tool: "run_command",
                             args: { "password" => "private-value", "padding" => "x" * 3000 })
    text = File.read(journal.path)
    refute_includes text, "ghp_", "clipping must not leave a credential fragment"
    refute_includes text, "private-value", "secret-key values must be masked before JSON becomes a preview"
    assert_includes text, Rubik::Security::Redactor::MASK_STRING
  end

  def test_finished_run_error_summary_is_redacted_and_bounded
    journal = Journal.new(path: journal_path("error-summary"))
    token = "ghp_#{'b' * 36}"
    journal.record_run_finished(run: 1, state: :failed, error_summary: "#{token} #{'x' * 1000}")

    summary = journal.read.records.first["data"]["error_summary"]
    refute_includes summary, token
    assert_includes summary, Rubik::Security::Redactor::MASK_STRING
    assert_includes summary, "truncated"
    assert_operator summary.length, :<, 450
  end

  def test_large_payloads_are_previewed_with_explicit_truncation_metadata
    journal = Journal.new(path: journal_path("clip"))
    journal.record_tool_call(run: 1, call_id: "c1", tool: "run_command", args: { "command" => "x" * 5000 })
    journal.record_tool_result(run: 1, call_id: "c1", tool: "run_command", status: :ok, duration_ms: 12.3,
                               output: "y" * 9000, artifact_ref: "rubik://subagent/sid/transcript")
    read = journal.read

    call = read.records[0]["data"]
    assert call["args_truncated"]
    refute call.key?("args"), "a clipped payload is replaced by its preview"
    assert_operator call["args_chars"], :>, 4000
    assert_includes call["args_preview"], "truncated"

    result = read.records[1]["data"]
    assert_equal 9000, result["output_chars"]
    assert result["output_truncated"], "replay can tell a clipped output from the original"
    assert_operator result["output_preview"].length, :<, 4200
    assert_includes result["output_preview"], "truncated 5000 chars"
    assert_equal "rubik://subagent/sid/transcript", result["artifact_ref"]
    assert_equal 12.3, result["duration_ms"]
  end

  # -------------------------------------------------------------- retention

  def test_retention_cap_marks_truncation_and_stops_appending
    journal = Journal.new(path: journal_path("cap"), config: { "subagents.journal.max_bytes" => 1024 })

    recorded = 0
    20.times do |i|
      recorded += 1 if journal.record_run_started(run: 1, role: "R", type: "t", prompt: "event #{i} #{'p' * 80}")
    end

    read = journal.read
    assert_operator recorded, :>=, 1, "the journal accepts records before the cap"
    assert_operator recorded, :<, 20, "the cap bounds the file independently of context size"
    assert read.truncated, "the cap writes a final truncation marker"
    assert_equal "journal_truncated", read.records.last["event"]
    assert_includes read.records.last["data"]["reason"], "retention cap reached"
    assert_operator File.size(journal.path), :<=, 1024, "the file stays within the documented cap"
    assert_nil journal.record_run_started(run: 1, role: "R", type: "t", prompt: "after the cap")
    assert_equal read.records.size, journal.read.records.size, "records are never rewritten"
  end

  def test_interrupted_final_write_does_not_hide_earlier_records
    path = journal_path("partial")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{\"seq\":1,\"run\":1,\"event\":\"run_started\",\"data\":{}}\n{\"seq\":2,\"run\":1,\"eve")

    read = Journal.read(path)
    assert_equal 1, read.records.size
    assert_equal 1, read.skipped, "the malformed tail is skipped and counted"
    refute read.truncated
    assert_equal "run_started", read.records.first["event"]
  end

  def test_persistence_failure_is_observable_and_never_raised
    path = journal_path("as-dir")
    FileUtils.mkdir_p(path) # a directory where the journal file belongs
    journal = Journal.new(path: path)

    result = begin
      journal.append("run_started", run: 1, data: { "x" => 1 })
    rescue StandardError => e
      flunk("append must never raise into the run: #{e.class}: #{e.message}")
    end

    assert_nil result
    refute_nil journal.last_error, "a failed write must be observable"
    assert_includes journal.last_error, "Errno::EISDIR"
  end

  # ------------------------------------------------------------ integration

  def test_run_journals_lifecycle_and_tool_correlation
    File.write(File.join(@ws_root, "notes.txt"), "hello journal\n")
    buffer = Rubik::Buffer::Manager.new(root_dir: @ws_root)
    registry = Rubik::Tools::Registry.build_default(buffer_manager: buffer, root_dir: @ws_root)
    call_count = 0
    response = Struct.new(:content, :tool_calls, :usage)
    resp_tool = response.new("Working", [{ "id" => "call-1", "tool" => "read_file", "args" => { "path" => "notes.txt" } }],
                             { input_tokens: 3, output_tokens: 2 })
    resp_done = response.new("Done", [], { input_tokens: 5, output_tokens: 7 })
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| (call_count += 1) == 1 ? resp_tool : resp_done }
    sup = new_supervisor(provider: provider, registry: registry, buffer_manager: buffer)
    profile = sup.type_registry.define_custom(
      name: "journal_scout", description: "Reads one file", system_prompt: "Read the requested file."
    )
    inst = sup.spawn(role: "Journalist", prompt: "read the notes", type_name: "journal_scout", max_steps: 3)
    assert(wait_until { inst.terminal_and_settled? })

    assert_equal File.join(File.dirname(inst.transcript_uri), "journal.jsonl"), inst.journal_path
    assert_equal inst.journal_path, inst.to_h[:journal]
    assert_nil inst.to_h[:journal_error]

    read = Journal.read(inst.journal_path)
    assert_equal 0, read.skipped
    events = read.records.map { |r| r["event"] }
    assert_equal ["run_started", "tool_call", "tool_result", "run_finished"], events
    runs = read.records.map { |r| r["run"] }
    assert_equal [1, 1, 1, 1], runs
    assert_equal read.records[1]["call_id"], read.records[2]["call_id"], "call and result correlate by call id"
    assert_equal "read_file", read.records[1]["data"]["tool"]
    assert_equal "ok", read.records[2]["data"]["status"]
    assert_kind_of Float, read.records[2]["data"]["duration_ms"]
    assert_includes read.records[2]["data"]["output_preview"], "hello journal"
    assert_equal "journal_scout", read.records.first["data"]["profile_name"]
    assert_equal profile.revision.to_s, read.records.first["data"]["profile_version"]
    assert_equal "completed", read.records.last["data"]["state"]
    finished = read.records.last["data"]
    assert_equal "completed", finished["outcome"]
    assert_equal "journal_scout", finished["profile_name"]
    assert_equal profile.revision.to_s, finished["profile_version"]
    assert_nil finished["error_summary"]
    assert_kind_of Integer, finished["duration_ms"]
    assert_operator finished["duration_ms"], :>=, 0
    assert_equal 2, finished["step_count"]
    assert_equal({ "read_file" => 1 }, finished["tool_usage"])
    assert_equal({ "status" => "reported", "model_responses" => 2,
                   "input_token_responses" => 2, "output_token_responses" => 2,
                   "input_tokens" => 8, "output_tokens" => 9 }, finished["token_usage"])
    assert_equal({ "status" => "unavailable" }, finished["cost"])
    assert_includes read.records.last["data"]["result_preview"], "Done"
  end

  def test_run_journal_marks_missing_provider_usage_unavailable
    sup = new_supervisor(provider: text_provider("Done"))
    inst = sup.spawn(role: "Journalist", prompt: "finish", type_name: "research", max_steps: 1)
    assert(wait_until { inst.terminal_and_settled? })

    finished = Journal.read(inst.journal_path).records.last["data"]
    assert_equal "research", finished["profile_name"]
    assert_equal "builtin", finished["profile_version"]
    assert_equal({ "status" => "unavailable", "model_responses" => 1 }, finished["token_usage"])
    assert_equal({ "status" => "unavailable" }, finished["cost"])
  end

  def test_compaction_events_never_remove_previously_journaled_events
    config = Rubik::Config.new(root_dir: @ws_root)
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-compact", parent_id: "agent-0", role: "Compactor", type_name: "research",
      prompt: "p", context: @root_context, tool_registry: nil, root_dir: @ws_root,
      config: config, context_limit: 100
    )
    inst.instance_variable_set(:@history, Array.new(8) { |i| { role: "user", content: "row #{i} #{'x' * 4000}" } })
    inst.journal.record_tool_call(run: 1, call_id: "c0", tool: "dummy", args: { "n" => 1 })
    before_history = inst.history.dup

    inst.evaluate_subagent_context_compaction!
    inst.instance_variable_set(:@history, inst.history + Array.new(8) { |i| { role: "user", content: "more #{i} #{'y' * 4000}" } })
    inst.evaluate_subagent_context_compaction!

    read = inst.journal.read
    events = read.records.map { |r| r["event"] }
    assert_operator events.count("compaction"), :>=, 1, "compaction is journaled"
    assert_includes events, "tool_call", "pre-compaction events survive"
    assert_equal "c0", read.records.find { |r| r["event"] == "tool_call" }["call_id"]

    # Model history was pruned (the original rows are gone from it) while the
    # journal kept them: independence is the point.
    inst.instance_variable_set(:@history, [])
    after_prune = inst.journal.read
    assert_equal read.records, after_prune.records, "pruning the model history never rewrites the journal"
    refute_equal before_history, inst.history
  end

  def test_cancellation_keeps_events_and_records_the_outcome
    gate = Queue.new
    call_count = 0
    resp_tool = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "call-9", "tool" => "ghost_tool", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      call_count += 1
      call_count == 1 ? resp_tool : gate.pop
    end
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Doomed", prompt: "work forever", max_steps: 5)
    assert(wait_until { call_count >= 2 && inst.state == :running }, "the worker must be parked mid-run")

    sup.kill(inst.id)
    assert(wait_until { inst.canceling? || inst.disposed? })

    read = Journal.read(inst.journal_path)
    events = read.records.map { |r| r["event"] }
    assert_includes events, "tool_call", "events recorded before the cancellation stay journaled"
    assert_includes events, "cancelled", "the cancellation outcome is recorded"
    assert_equal "call-9", read.records.find { |r| r["event"] == "tool_result" }["call_id"]
  end

  def test_redeploy_keeps_earlier_runs_in_the_same_journal
    responses = ["first done", "second done"]
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| Struct.new(:content, :tool_calls).new(responses.shift, []) }
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Reuser", prompt: "first task", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? })

    sup.redeploy(inst.id, prompt: "second task", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? && inst.result == "second done" })

    read = Journal.read(inst.journal_path)
    assert_equal [1, 2], read.records.select { |r| r["event"] == "run_started" }.map { |r| r["run"] },
                 "redeployed runs are distinguished by their run sequence"
    run_one = read.records.select { |r| r["run"] == 1 }
    assert_equal "completed", run_one.find { |r| r["event"] == "run_finished" }["data"]["state"],
                 "the earlier run's outcome is preserved"
    assert_includes run_one.find { |r| r["event"] == "run_started" }["data"]["prompt_preview"], "first task"
    assert_equal (1..read.records.size).to_a, read.records.map { |r| r["seq"] }, "sequence is monotonic across runs"
  end
end
