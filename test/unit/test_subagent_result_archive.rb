# frozen_string_literal: true

require_relative "../test_helper"

# Issue #122: paginated access to complete subagent results without a
# redeploy. The ResultArchive retains each settled run's redacted result
# under an execution-specific reference (storage id + run sequence), wait
# rows/notices/storage summaries point at it, and reads page through it in
# memory — no model call, no execution-state change, no workspace gate.
class TestSubagentResultArchive < Minitest::Test
  ResultArchive = Rubik::Orchestrator::Subagent::ResultArchive

  def setup
    @ws_root = mint_test_root
    @outside = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root && File.directory?(@ws_root)
    remove_temp_dir(@outside) if @outside && File.directory?(@outside)
  end

  def new_supervisor(provider: done_provider, config: nil)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config
    )
  end

  def done_provider(content = "All done")
    text_provider(content)
  end

  def text_provider(content, &counter)
    resp = Struct.new(:content, :tool_calls).new(content, [])
    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      counter&.call
      resp
    end
    provider
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end

  def spawn_completed(sup, content, provider: nil)
    inst = sup.spawn(role: "Reporter", prompt: "report", max_steps: 3,
                     provider: provider || text_provider(content))
    assert wait_until { inst.terminal_and_settled? }, "run must settle"
    inst
  end

  def manage_tool(sup)
    Rubik::Tools::ManageSubagentsTool.new(supervisor: sup, runtime_context: @root_context)
  end

  # ------------------------------------------------------------ archive core

  def test_pages_reconstruct_a_long_unicode_result_without_loss_or_duplication
    archive = ResultArchive.new(page_chars: 7)
    body = "Résumé ✓ — #{'satır-ı uzun ✓ ' * 40}SON"
    archive.retain(storage_id: "sid-1", id: "subagent-1", run: 1, state: :completed, body: body)

    pages = []
    cursor = 0
    loop do
      page = archive.read(storage_id: "sid-1", run: 1, cursor: cursor)
      assert page.ok?, "page read must succeed"
      assert_equal body.length, page.total_chars
      assert_equal page.body.length, page.returned_chars
      assert_equal cursor, page.cursor
      assert page.body.valid_encoding?, "pages never split multibyte characters"
      pages << page.body
      break unless page.has_more

      assert_operator page.next_cursor, :>, cursor, "the cursor advances"
      cursor = page.next_cursor
    end

    assert_operator pages.size, :>, 5, "the long result really was paged"
    assert_equal Rubik::Security::Redactor.redact(body), pages.join,
                 "concatenated pages reconstruct the retained result in order (no gaps, no duplicates)"
  end

  def test_page_metadata_and_cursor_errors_are_explicit
    archive = ResultArchive.new(page_chars: 5)
    archive.retain(storage_id: "sid-meta", id: "subagent-9", run: 3, state: :completed, body: "0123456789")

    page = archive.read(storage_id: "sid-meta", run: 3, limit: 4)
    assert_equal 0, page.cursor
    assert_equal 4, page.next_cursor
    assert page.has_more
    assert_equal 10, page.total_chars
    assert_equal 4, page.returned_chars
    assert page.redacted
    refute_empty page.ref

    last = archive.read(storage_id: "sid-meta", run: 3, cursor: 8)
    assert_equal "89", last.body
    refute last.has_more
    assert_nil last.next_cursor
    assert_equal 2, last.returned_chars

    bad = archive.read(storage_id: "sid-meta", run: 3, cursor: 99)
    refute bad.ok?
    assert_equal :cursor, bad.reason
    assert_includes bad.message, "Cursor 99"
  end

  def test_unknown_and_expired_references_answer_explicitly
    now = Time.utc(2026, 1, 1)
    archive = ResultArchive.new(ttl_seconds: 60, clock: -> { now })

    missing = archive.read(storage_id: "ghost")
    refute missing.ok?
    assert_equal :unknown, missing.reason
    assert_includes missing.message, "No retained result for execution 'ghost'"

    archive.retain(storage_id: "sid-2", id: "subagent-2", run: 1, state: :completed, body: "keep me")
    assert_equal "keep me", archive.read(storage_id: "sid-2").body

    now += 61 # cross the TTL
    expired = archive.read(storage_id: "sid-2", run: 1)
    refute expired.ok?
    assert_equal :expired, expired.reason
    assert_includes expired.message, "expired at"
    assert_includes expired.message, "retention: 60s"
    refute archive.known?("sid-2"), "an expired entry is gone, not silently served"

    archive.retain(storage_id: "sid-2", id: "subagent-2", run: 2, state: :completed, body: "fresh")
    unknown_run = archive.read(storage_id: "sid-2", run: 9)
    refute unknown_run.ok?
    assert_equal :unknown, unknown_run.reason
    assert_includes unknown_run.message, "retained run(s): 2"
  end

  def test_redeploy_runs_are_retained_side_by_side_bounded_by_max_runs
    archive = ResultArchive.new(max_runs_per_instance: 2)
    archive.retain(storage_id: "sid-3", id: "subagent-3", run: 1, state: :completed, body: "first run")
    archive.retain(storage_id: "sid-3", id: "subagent-3", run: 2, state: :failed, body: "")

    assert_equal "first run", archive.read(storage_id: "sid-3", run: 1).body,
                 "the redeploy run does not overwrite its predecessor"
    latest = archive.read(storage_id: "sid-3")
    assert_equal 2, latest.run, "no run given = latest retained"
    assert_equal "", latest.body

    archive.retain(storage_id: "sid-3", id: "subagent-3", run: 3, state: :completed, body: "third run")
    evicted = archive.read(storage_id: "sid-3", run: 1)
    refute evicted.ok?
    assert_equal :unknown, evicted.reason
    assert_includes evicted.message, "newest 2 run(s)"
    assert_equal "third run", archive.read(storage_id: "sid-3").body
  end

  def test_retained_bodies_are_redacted_before_serving
    archive = ResultArchive.new
    token = "ghp_#{'a' * 36}"
    archive.retain(storage_id: "sid-4", id: "subagent-4", run: 1, state: :completed,
                   body: "verdict: leaked #{token} here")

    page = archive.read(storage_id: "sid-4")
    refute_includes page.body, token, "credentials never reach the retained copy"
    assert_includes page.body, Rubik::Security::Redactor::MASK_STRING
  end

  # -------------------------------------------------- end-to-end retrieval

  def test_wait_truncation_reference_reads_through_read_file_without_workspace_access
    calls = 0
    long = "REPORT #{'veri ✓ ' * 700}END"
    sup = new_supervisor(provider: nil)
    inst = spawn_completed(sup, long, provider: text_provider(long) { calls += 1 })
    assert_operator calls, :>=, 1, "the run really called the provider"

    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, sup)
    wait_rows = manage_tool(sup).execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 3)
    ref = inst.result_ref
    assert_equal "rubik://subagent/#{inst.storage_id}/result/1", ref
    assert_includes wait_rows, "[truncated — full result: read_file(path: '#{ref}')]",
                    "a truncated preview must hand the canonical retrieval reference"

    reads_before = calls
    # The reader's workspace root is a DIFFERENT temp dir than the supervisor's:
    # the reference must not need any allowlisting to resolve.
    reader = Rubik::Tools::ReadFileTool.new(Rubik::Buffer::Manager.new(root_dir: @outside), runtime_context: @root_context)
    page1 = reader.execute("path" => ref)
    assert_kind_of String, page1, "the canonical reference must read through read_file"
    assert_includes page1, "Retained result #{ref}"
    assert_includes page1, "REPORT"
    assert_includes page1, "More content follows — next page: manage_subagents(action: 'result'",
                    "the first page carries its own paginated continuation"

    assert_equal reads_before, calls, "result reads make zero model calls"
    assert_equal :completed, inst.state, "result reads never change execution state"
    assert_equal ref, sup.get(inst.id).result_ref, "no redeploy happened behind the read"

    missing = reader.execute("path" => Rubik::Uris.subagent_result("ghost-storage-id"))
    assert missing.respond_to?(:error?) && missing.error?, "an unknown reference returns an explicit error"
    assert_includes missing.to_s, "No retained result"
  end

  def test_result_action_pages_the_retained_result_without_state_change
    long = "PAGE-#{'veri ✓ ' * 900}"
    sup = new_supervisor(provider: text_provider(long))
    inst = spawn_completed(sup, long)
    tool = manage_tool(sup)

    first = tool.execute("action" => "result", "conversation_id" => inst.id, "limit" => 100)
    assert_includes first, "Retained result #{inst.result_ref}"
    assert_includes first, "More content follows"
    cursor = first[/cursor: (\d+)\)/, 1].to_i
    assert_operator cursor, :>, 0

    second = tool.execute("action" => "result", "conversation_id" => inst.id, "limit" => 100, "cursor" => cursor)
    assert_includes second, "chars #{cursor}-"
    assert_equal :completed, inst.state, "reading a result never redeploys or mutates the run"

    out_of_range = tool.execute("action" => "result", "conversation_id" => inst.id, "cursor" => long.length + 10)
    assert out_of_range.error?
    assert_includes out_of_range.to_s, "exceeds the retained result length"
  end

  def test_result_action_survives_tombstone_eviction_via_the_raw_storage_id
    sup = new_supervisor(provider: text_provider("survives"), config: { "subagents.tombstone_limit" => 0 })
    inst = spawn_completed(sup, "survives")
    assert_equal [inst.id], sup.reap_finished!(force: true)
    assert_nil sup.get(inst.id), "precondition: the roster forgot the execution"

    res = manage_tool(sup).execute("action" => "result", "conversation_id" => inst.storage_id)
    assert_includes res, "Retained result #{inst.result_ref}", "the archive is independent of the reaped roster"
    assert_includes res, "survives"
  end

  def test_result_action_answers_unknown_ids_explicitly
    sup = new_supervisor
    res = manage_tool(sup).execute("action" => "result", "conversation_id" => "ghost-1")
    assert res.error?
    assert_includes res.to_s, "not found and no retained result"
  end

  # -------------------------------------------- notice + summary references

  def test_completion_notice_carries_the_result_reference
    payload = nil
    @bus.subscribe(Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT) { |p| payload = p }
    sup = new_supervisor(provider: text_provider("notice body"))
    inst = sup.spawn(role: "Notifier", prompt: "report", max_steps: 2)
    assert wait_until { inst.terminal_and_settled? && payload }, "completion notice must arrive"

    assert_equal inst.result_ref, payload[:result_ref], "the completion notice carries the canonical reference"

    notice = Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT, payload
    )
    assert_equal inst.result_ref, notice[:result_ref]
    element = Rubik::Orchestrator::Subagent::Notices.model_element(notice)
    assert_includes element, %(result_ref="#{inst.result_ref}"), "the model channel exposes the reference"
    guidance = Rubik::Orchestrator::Subagent::Notices.guidance_for(notice)
    assert_includes guidance, "read_file(path: '#{inst.result_ref}')",
                    "the retrieval guidance is a route that actually works"
  end

  def test_storage_summary_links_and_body_carry_the_reference
    sup = new_supervisor(provider: text_provider("searchable verdict"))
    inst = spawn_completed(sup, "searchable verdict")
    store = Rubik::Storage::Store.new(root: @outside, project: "resultproj")
    Rubik::Storage::TranscriptIndexer.index(store, inst)

    record = store.get(type: "transcript", id: Rubik::Uris.transcript_ref(inst.storage_id))
    refute_nil record
    assert_equal inst.result_ref, record["links"]["result"]
    assert_includes record["body"], "[retrieve] #{inst.result_ref}"
    assert_includes record["body"], "searchable verdict"
  end

  def test_redeploy_retains_both_runs_under_distinct_references
    responses = ["FIRST-RESULT", "SECOND-RESULT"]
    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      Struct.new(:content, :tool_calls).new(responses.shift, [])
    end
    sup = new_supervisor(provider: provider)
    inst = sup.spawn(role: "Reuse", prompt: "first", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? && inst.result == "FIRST-RESULT" })
    first_ref = inst.result_ref
    assert_equal 1, inst.run_seq

    sup.redeploy(inst.id, prompt: "second", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? && inst.run_seq == 2 && inst.result == "SECOND-RESULT" })
    second_ref = inst.result_ref
    refute_equal first_ref, second_ref, "each run owns an execution-specific reference"

    archive = sup.result_archive
    assert_equal "FIRST-RESULT", archive.read(storage_id: inst.storage_id, run: 1).body,
                 "redeploy never overwrites the earlier retained run"
    assert_equal "SECOND-RESULT", archive.read(storage_id: inst.storage_id, run: 2).body
    assert_equal 2, archive.read(storage_id: inst.storage_id).run

    rows = sup.wait_for([inst.id])
    assert_equal second_ref, rows.first[:result_ref], "wait rows advertise the latest run's reference"
  end
end
