# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Session review bugfix batch (2026-10-07, fffcr session report
# rubik://storage/fffcr/review/review.2.eb263d1c14a6ea2a): one test class per
# report bug id so the fixes stay traceable — B1 dmesg payload, B3/B4/B11
# budget family, B5 id dialects, B6 distiller rejection, B8 exit-code
# taxonomy, B9 ignored dirs, B10 truncation URI, B3-delay stranded notices,
# B7 sandbox note + cmd builtins.
class TestSessionReviewBugfixes < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: Dir.pwd)
    @tool_registry = Rubik::Tools::Registry.build_default(buffer_manager: @buffer_manager, root_dir: Dir.pwd)
    @supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      buffer_manager: @buffer_manager,
      tool_registry: @tool_registry,
      root_dir: @ws_root
    )
  end

  def teardown
    @supervisor&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  # ---- B1: dmesg line renders event payload facts -------------------------

  def test_b1_dmesg_line_renders_payload_data_as_key_values
    ring = Rubik::Kernel::Dmesg.new
    ring.log(:mcp, :err, "event:mcp_server_failed", server: "edge-mcp", error: "handshake timed out")
    line = ring.formatted

    assert_includes line, "event:mcp_server_failed"
    assert_includes line, "server=edge-mcp", "the failing server name must be visible in the line (B1)"
    assert_includes line, "error=handshake timed out"
  end

  def test_b1_poisoned_payload_bytes_never_break_the_dmesg_view
    ring = Rubik::Kernel::Dmesg.new
    ring.log(:llm, :err, "event:provider_failed", body: "\xFF\xFEraw-http-body".b)
    ring.log(:mcp, :info, "event:ok", note: "still readable")

    lines = ring.formatted

    assert_includes lines, "event:ok", "one binary record must not cost the whole ring view (B1 review fix)"
    assert lines.is_a?(String)
  end

  def test_b1_payload_suffix_tails_long_values_and_caps_key_count
    record = Rubik::Kernel::Record.new(
      seq: 1, uptime: 0.5, subsystem: :mcp, level: :err, facility_id: nil,
      message: "event:x", data: { blob: "z" * 500, k2: 1, k3: 1, k4: 1, k5: 1, k6: 1, k7: 1, k8: 1 }
    )
    line = Rubik::Kernel.format_line(record)

    refute_includes line, "z" * 300, "long values are tailed, not dumped whole"
    assert_includes line, "(+2 more)", "key count is capped with an overflow marker"
  end

  def test_b1_records_without_data_render_exactly_as_before
    record = Rubik::Kernel::Record.new(
      seq: 2, uptime: 0.123456, subsystem: :kernel, level: :info, facility_id: nil,
      message: "Boot complete.", data: {}
    )
    assert_equal "[   +0.123456] [kernel] INFO: Boot complete.", record.format_line
  end

  # ---- B5: conversation_ids dialects --------------------------------------

  def test_b5_wait_accepts_json_encoded_array_string
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst1 = @supervisor.spawn(role: "Worker One", prompt: "P1")
    inst2 = @supervisor.spawn(role: "Worker Two", prompt: "P2")
    ids_json = JSON.generate([inst1.id, inst2.id])

    res = tool.execute("action" => "wait", "conversation_ids" => ids_json, "timeout" => 3)

    assert_includes res, "Subagents wait finished (2 tracked)", "both ids from the stringified array must resolve (B5)"
    assert_includes res, inst1.id
    assert_includes res, inst2.id
  end

  def test_b5_status_resolves_stringified_array_and_comma_list
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    inst = @supervisor.spawn(role: "Statusable", prompt: "P")

    status = tool.execute("action" => "status", "conversation_id" => JSON.generate([inst.id]))
    assert_includes status, inst.id
    assert_includes status, '"state"', "status must find the instance instead of hunting the raw array string"

    wait_both = tool.execute("action" => "wait", "conversation_ids" => "#{inst.id}, #{inst.id}", "timeout" => 3)
    assert_includes wait_both, inst.id
  end

  def test_b5_kill_without_ids_shows_expected_format
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)

    res = tool.execute("action" => "kill")

    assert_includes res, "conversation_ids", "the error must teach the expected format (B5)"
    assert_includes res, '["subagent-5", "subagent-6"]'
  end

  def test_b5_wait_unknown_ids_name_them
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)

    res = tool.execute("action" => "wait", "conversation_ids" => ["ghost-1", "ghost-2"], "timeout" => 1)

    assert_includes res, "Unknown id(s): ghost-1, ghost-2"
  end

  # ---- B10: wait truncation carries the transcript URI --------------------

  def test_b10_truncated_wait_result_points_at_transcript_uri
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor, runtime_context: @root_context)
    long_answer = "R" * 2500
    inst = @supervisor.spawn(role: "Reporter", prompt: "P", provider: text_provider(long_answer))
    assert wait_until { inst.state == :completed }, "worker must finish with the long report"

    res = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 3)

    # Issue #122 supersedes the raw transcript path here: truncation now hands
    # the canonical retained-result reference, which read_file resolves inside
    # the runtime (no workspace gate, no external storage path).
    assert_includes res, "[truncated — full result: read_file(path: '#{inst.result_ref}')]",
                    "truncation must hand the canonical result reference (B10 + #122)"
  end

  # ---- B3/B4/B11: budget grant liveness + halt message + pause payload ----

  def test_b3_grant_clears_stale_pause_result_summary
    inst = @supervisor.spawn(role: "Awaiting", prompt: "P", max_steps: 3, provider: always_tool_provider)
    assert(wait_until { inst.state == :waiting_budget })
    assert_includes inst.to_h[:state_note], "Paused awaiting budget expansion",
                    "precondition: the pause story is visible — derived from state, not stored"

    @supervisor.extend_budget(inst.id, 5)

    snapshot = inst.to_h
    assert_equal "running", snapshot[:state]
    assert_nil snapshot[:result_summary], "result is terminal-only: no pause placeholder can ever survive the grant (B3)"
    assert_nil snapshot[:result]
    assert_nil snapshot[:state_note], "a running state carries no invented prose"
    assert_equal 1, snapshot[:grants_received]
  end

  def test_b4_halt_message_distinguishes_no_grant_from_no_further_grant
    exhausted_instance(grants: 0) do |no_grant|
      assert_includes no_grant.to_h[:state_note], "Budget expansion was not received from the maestro.",
                      "first exhaustion keeps the plain not-received wording (B4)"
    end

    exhausted_instance(grants: 1) do |granted|
      halted = granted.to_h[:state_note]
      assert_includes halted, "No further budget expansion arrived"
      assert_includes halted, "1 grant(s) were received and consumed earlier",
                      "a consumed grant must not read as a lost one (B4)"
    end
  end

  def test_b4_error_resume_grant_is_counted_in_grant_telemetry
    # Review B4 fix: a grant delivered through the ERROR-resume path must
    # reach the same accounting (counter + subagent-visible note), or a later
    # halt would claim no grant ever arrived.
    cfg = Rubik::Config.new
    cfg.set("subagents.network_retry_count", 0, persist: false) # fail through to the error pause, no retry loop
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: cfg, root_dir: @ws_root)
    attempts = 0
    resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) do |_h, _o = {}|
      attempts += 1
      attempts == 1 ? raise(Errno::ECONNRESET, "connection reset by peer") : resp
    end
    inst = sup.spawn(role: "Flaky", prompt: "P", max_steps: 2, provider: provider)
    assert wait_until { inst.state == :paused_error }, "first call must error-pause the worker"

    assert inst.resume!(additional_steps: 10), "resume with steps must succeed"
    snapshot = inst.to_h
    assert_equal 1, snapshot[:grants_received], "the error-resume grant is accounted (B4 review fix)"
    assert_nil snapshot[:last_error]
    assert snapshot[:max_steps] >= 10
  ensure
    sup&.shutdown_all
  end

  def test_b11_pause_notice_carries_grant_cycle_marker
    notice = Rubik::Orchestrator::Subagent::Notices.normalize(
      Rubik::Orchestrator::Subagent::Notices::BUDGET_EXHAUSTED_EVENT,
      { id: "subagent-5", role: "Worker", state: :waiting_budget, max_steps: 75, grants: 2, step: 75 }
    )
    line = Rubik::Orchestrator::Subagent::Notices.user_line(notice)

    assert_includes line, "again (after 2 grant(s) consumed, at step 75)",
                    "repeated pauses must be distinguishable at a glance (B11)"
  end

  # ---- B8: search-tool exit 1 is NO_MATCH, not UNKNOWN_FAILURE ------------

  def test_b8_grep_exit_one_clean_streams_is_no_match
    diag = Rubik::Runtime::DiagnosticEngine.diagnose(cmd: "grep -rn TODO lib/", exit_code: 1, stdout: "", stderr: "")

    assert_equal :no_match, diag.category
    assert_includes diag.format_for_llm, "NO_MATCH"
    assert_includes diag.suggestion, "matched nothing"
  end

  def test_b8_grep_real_error_stays_a_failure
    exit2 = Rubik::Runtime::DiagnosticEngine.diagnose(cmd: "grep -rn TODO /etc/shadow", exit_code: 2, stdout: "", stderr: "grep: /etc/shadow: Permission denied")
    assert_equal :permission_denied, exit2.category, "exit 2 is a real error, never NO_MATCH"

    noisy = Rubik::Runtime::DiagnosticEngine.diagnose(cmd: "grep pattern file", exit_code: 1, stdout: "", stderr: "grep: fatal error")
    refute_equal :no_match, noisy.category, "error text suppresses the NO_MATCH reading"
  end

  def test_b8_git_grep_prefix_counts_as_search_tool
    diag = Rubik::Runtime::DiagnosticEngine.diagnose(cmd: "git grep TODO", exit_code: 1, stdout: "", stderr: "")
    assert_equal :no_match, diag.category
  end

  # ---- B9: list_files explains an ignored-but-existing directory ----------

  class FakeIndex
    def initialize(files)
      @files = files
    end
    attr_reader :files

    def full_scan
      @files
    end

    def additional_roots
      []
    end
  end

  def test_b9_existing_but_unindexed_directory_gets_an_explanation
    root = Dir.mktmpdir("rubik_listfiles")
    begin
      FileUtils.mkdir_p(File.join(root, "lib"))
      tool = Rubik::Tools::ListFilesTool.new(FakeIndex.new({}), root_dir: root)

      res = tool.execute("path" => "lib")

      assert_includes res, "EXISTS on disk", "the directory exists and the tool must say so (B9)"
      assert_includes res, "ignore rules"
      refute_includes res, "No matching files found"
    ensure
      remove_temp_dir(root)
    end
  end

  def test_b9_missing_directory_keeps_the_plain_no_match
    root = Dir.mktmpdir("rubik_listfiles2")
    begin
      tool = Rubik::Tools::ListFilesTool.new(FakeIndex.new({}), root_dir: root)

      res = tool.execute("path" => "nope")

      assert_includes res, "No matching files found for 'nope'."
    ensure
      remove_temp_dir(root)
    end
  end

  def test_b9_extension_miss_in_an_indexed_directory_is_not_blamed_on_ignore_rules
    root = Dir.mktmpdir("rubik_listfiles3")
    begin
      FileUtils.mkdir_p(File.join(root, "lib"))
      idx = FakeIndex.new({ "lib/a.rb" => {}, "lib/b.rb" => {} })
      tool = Rubik::Tools::ListFilesTool.new(idx, root_dir: root)

      res = tool.execute("path" => "lib", "extension" => ".go")

      assert_includes res, "No matching files found for 'lib'.", "an extension miss in an INDEXED dir is a plain no-match (B9 review fix)"
      refute_includes res, "ignore rules"
    ensure
      remove_temp_dir(root)
    end
  end

  # ---- B6: distiller rejection reason + one-shot over-length trim ---------

  def test_b6_rejection_reason_is_human_readable
    gate = Rubik::Storage::Vakanuvis::DistillGate
    proposal, reason = gate.validate_proposal_with_reason("not-a-ref\nbody text that is long enough to pass minimums yes.", expected_ref: nil)

    assert_nil proposal
    assert_includes reason, "first line is not a target ref", "the rejection says WHY (B6)"

    _p, mismatch = gate.validate_proposal_with_reason("wiki.other\n#{'x' * 200}", expected_ref: "wiki.wanted")
    assert_includes mismatch, "does not match the queued digest"
  end

  def test_b6_over_length_proposal_is_trimmed_once_instead_of_dropped
    gate = Rubik::Storage::Vakanuvis::DistillGate
    body = ("para\n\n" * 6000) # ~30k chars > BODY_MAX
    finish_body = "wiki.long-page\n#{body}"

    proposal, reason = gate.validate_proposal_with_reason(finish_body)
    assert_nil proposal
    assert_equal :body_over_hard_cap, reason, "the trim branch keys on a symbol, never on prose (B6)"

    trimmed = gate.trimmed_proposal(finish_body)
    assert trimmed, "structure is otherwise valid — trim must succeed"
    assert trimmed["body"].size <= Rubik::Storage::Vakanuvis::DistillGate::BODY_MAX
    assert_includes trimmed["body"], "auto-trimmed", "the page carries the trim stamp"
  end

  # ---- B3-delay: stranded loop notices are delivered after the turn -------

  class FakeLoopWithInbox
    def initialize(notices)
      @inbox = Rubik::Orchestrator::SubagentNoticeInbox.new
      notices.each { |n| @inbox.enqueue(n) }
    end

    # The real Loop exposes the lazy reader with this exact name; the delivery
    # seam keys on it.
    def subagent_notice_inbox
      @inbox
    end
  end

  def test_b3_delay_stranded_notices_reach_history_and_arm_wake
    shell = lifecycle_double(FakeLoopWithInbox.new([
                                                     { kind: :budget_exhausted, id: "subagent-5", role: "W", state: "waiting_budget", max_steps: 60 },
                                                     { kind: :context_compacted, id: "subagent-6", role: "W", state: "running" }
                                                   ]))

    shell.deliver_stranded_loop_notices!(shell.active_loop)

    xml = shell.conversation_history.map { |h| h[:content] }.join
    assert_includes xml, "<subagent_notifications>", "the model channel must enter history (B3 turn-loss)"
    assert_includes xml, 'kind="budget_exhausted"'
    assert_includes xml, 'kind="context_compacted"'

    wake_kinds = shell.pending_notice_queue.drain_all.map { |n| n[:kind] }
    assert_includes wake_kinds, :budget_exhausted, "wake-worthy notice arms the reactive wake"
    refute_includes wake_kinds, :context_compacted, "non-wake kinds stay information-only"
  end

  def test_b3_delay_empty_inbox_is_a_noop
    shell = lifecycle_double(FakeLoopWithInbox.new([]))
    shell.deliver_stranded_loop_notices!(shell.active_loop)

    assert_empty shell.conversation_history
    refute shell.pending_wake_notices?
  end

  # ---- B7: isolation note knob + cmd builtin routing -----------------------

  def test_b7_isolation_note_can_be_silenced_by_config
    cfg = Rubik::Config.new(root_dir: @ws_root, home_dir: @ws_root)
    cfg.set("sandbox.isolation_note", false, persist: false)
    fake_driver = Object.new
    fake_driver.define_singleton_method(:run) { |*, **| { ok: true, exit_code: 0, stdout: "done", stderr: "", output: "done", duration: 0.1, driver: "fake", shell: "bash" } }
    fake_driver.define_singleton_method(:name) { "fake" }
    runner = Rubik::Sandbox::Runner.new(root_dir: @ws_root, driver: fake_driver, config: cfg)

    res = runner.run("echo hi")

    refute res[:isolation], "sandbox.isolation_note=false must silence the per-run note (B7)"

    cfg.set("sandbox.isolation_note", true, persist: false)
    res_note = runner.run("echo hi")
    assert res_note[:isolation], "default (true) keeps the historical disclosure"
  end

  def test_b7_cmd_builtins_route_to_cmd_even_with_posix_noise
    resolver = Rubik::Sandbox::ShellResolver

    assert_equal "cmd", resolver.gate("dir 'some filter'", :windows), "a cmd builtin must not fall through to bash (B7)"
    assert_equal "cmd", resolver.gate("where git", :windows)
    refute_equal "cmd", resolver.gate("dir listing", :linux), "non-Windows hosts are untouched"
    assert_equal "bash", resolver.gate("grep foo $(pwd)", :windows), "real binaries keep their POSIX-syntax routing"
    # Review B7: bash-mandatory syntax outranks the builtin route — cmd would
    # mangle /dev/null into a bogus drive path.
    assert_equal "bash", resolver.gate("where git 2>/dev/null", :windows)
    assert_equal "bash", resolver.gate("dir <<'EOF'\nlist\nEOF", :windows)
  end

  private

  def lifecycle_double(active_loop)
    output = StringIO.new
    Class.new do
      include Rubik::REPL::Lifecycle

      attr_accessor :active_loop, :output, :running, :replaying, :subagent_notices_mutex,
                    :subagent_notices, :config, :terminal_guard, :conversation_history

      def initialize(active_loop, output)
        @active_loop = active_loop
        @output = output
        @running = true
        @replaying = false
        @subagent_notices_mutex = Mutex.new
        @subagent_notices = []
        @config = nil
        @terminal_guard = nil
        @conversation_history = []
      end
    end.new(active_loop, output)
  end

  def wait_until
    deadline = Time.now + 5
    until (value = yield)
      return false if Time.now >= deadline

      sleep 0.02
    end
    value
  end

  # A provider whose every answer asks for another tool call: parks at budget.
  def always_tool_provider
    resp = Struct.new(:content, :tool_calls).new("Working", [{ "id" => "c1", "tool" => "dummy", "args" => {} }])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| resp }
    provider
  end

  # A provider that immediately finishes with the given text.
  def text_provider(text)
    resp = Struct.new(:content, :tool_calls).new(text, nil)
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| resp }
    provider
  end

  # Drives a worker to :budget_exhausted; grants budget first when grants > 0
  # so the halt wording exercises the "further expansion" branch (B4).
  # YIELDS while the worker is parked at :budget_exhausted — derived
  # narration reflects the CURRENT state, so assertions must read it in the
  # live window (the old stored placeholder survived the helper's teardown;
  # the derived note correctly answers nil for a disposed instance).
  def exhausted_instance(grants:)
    cfg = Rubik::Config.new
    cfg.set("subagents.budget_wait_timeout", 0.05, persist: false)
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, config: cfg, root_dir: @ws_root, provider: always_tool_provider
    )
    inst = sup.spawn(role: "Exhaustee", prompt: "P", max_steps: 2)
    assert(wait_until { inst.state == :waiting_budget })
    inst.extend_budget(10) if grants.positive?
    assert wait_until { inst.state == :budget_exhausted }, "worker must time out its budget wait"
    yield inst
  ensure
    sup&.shutdown_all
  end
end
