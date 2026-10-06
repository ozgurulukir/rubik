# frozen_string_literal: true

require_relative "../test_helper"

# Kök-turn kroniği (root-turn planı 2026-10-04): REPL turn sınırındaki
# :turn_finished emisyonu → harness tek deterministik satır üretir.
# Sözleşme: satır yalnız payload'dan türer (duvar saati yok), tools/tokens
# boşsa alan da yoktur, ordinal harness-lokal sayaçtır, sessizlik (notice
# yok, WAKE_KINDS dışı) ve flush sayacı davranışı (R8) burada kilitlenir.
class TestVakanuvisRootTurn < Minitest::Test
  SLUG = "root-turn-session"

  def setup
    @root = Dir.mktmpdir("rubik_root_turn")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def store
    Rubik::Storage::Store.new(root: @root, project: "RootTurn Test")
  end

  def harness(store_obj = store, **)
    Rubik::Storage::Vakanuvis::Harness.new(store: store_obj, session_slug: SLUG, **)
  end

  # Gerçek üretici (Loop) token sayacı Hash'tir: {input:, output:}. Test
  # ikizi üretim şeklini modeller — Integer pinleyip CRITICAL şekil
  # kaymasını (Hash.to_i → NoMethodError → olay düşer) gizlemek yok.
  def turn_event(kind: "success", prompt: "fix the login bug", outcome: "patched auth.rb",
                 tools: "read_file(x2) storage(x1)", tokens: { input: 1234, output: 56 })
    { kind: kind, prompt: prompt, outcome: outcome, tools: tools, tokens: tokens }
  end

  def session_body(store_obj)
    rec = store_obj.get(type: "note", id: Rubik::Storage::Vakanuvis::AnnalWriter.session_ref(SLUG))
    rec ? rec["body"].to_s : ""
  end

  class SpyBus
    attr_reader :posts, :subscriptions

    def initialize
      @posts = []
      @subscriptions = []
    end

    def subscribe(name, _context = nil, &blk)
      @subscriptions << name
      blk
    end

    def post(name, payload = {}, **kwargs)
      @posts << [name, payload, kwargs]
      true
    end
  end

  # ---- annal satırı ---------------------------------------------------------

  def test_turn_event_writes_deterministic_session_line
    h = harness
    h.start!
    h.enqueue_event(:turn, turn_event)
    assert h.wait_idle
    h.shutdown

    body = session_body(h.store)
    assert_includes body, "turn 1 kind=success prompt=fix the login bug", "line carries ordinal + kind + prompt"
    assert_includes body, "tools=read_file(x2) storage(x1)", "tool tally is part of the chronicle"
    assert_includes body, "tokens=1290", "Hash token counter renders as its scalar sum (input+output)"
    assert_includes body, "outcome=patched auth.rb"
    assert_includes body, "(event=turn.1.success)"
    refute_includes body, Time.now.year.to_s, "turn lines carry no wall clock — pure event data"
  end

  def test_turn_ordinals_increment_and_identical_payloads_stay_distinct
    h = harness
    h.start!
    h.enqueue_event(:turn, turn_event)
    h.enqueue_event(:turn, turn_event)
    assert h.wait_idle
    h.shutdown

    body = session_body(h.store)
    assert_includes body, "(event=turn.1.success)"
    assert_includes body, "(event=turn.2.success)",
                    "ordinal-keyed uniqueness: two identical turns are two history rows, not a dedup collision"
  end

  def test_turn_line_omits_empty_tools_and_tokens
    h = harness
    h.start!
    h.enqueue_event(:turn, turn_event(tools: "", tokens: nil))
    assert h.wait_idle
    h.shutdown

    body = session_body(h.store)
    refute_includes body, "tools=", "empty tool tally must not render a field"
    refute_includes body, "tokens=", "nil/zero tokens must not render a field"
  end

  def test_turn_line_collapses_and_truncates_unruly_payloads
    h = harness
    h.start!
    h.enqueue_event(:turn, turn_event(prompt: "multi\nline | prompt", outcome: "x" * 500))
    assert h.wait_idle
    h.shutdown

    body = session_body(h.store)
    line = body.lines.find { |l| l.include?("kind=success") }
    assert line, "turn line must exist"
    refute_match(/\n/, line.chomp, "no embedded newlines — the dedup key rides the line tail")
    assert_includes line, "multi line / prompt", "newline and pipe are flattened by one_line"
    assert_operator line.length, :<, 400, "long outcome must be truncated (one_line ellipsis)"
  end

  # ---- flush sayacı (R8) ----------------------------------------------------

  def test_turn_events_count_toward_the_flush_threshold
    cfg = { "subagents.vakanuvis.flush_events" => 3 }
    h = harness(store, config: cfg)
    h.start!
    2.times { h.enqueue_event(:turn, turn_event) }
    assert h.wait_idle
    refute h.store.get(type: "wiki", id: "wiki.home"), "below threshold: maintain must not run"

    h.enqueue_event(:turn, turn_event)
    assert h.wait_idle
    h.shutdown
    assert h.store.get(type: "wiki", id: "wiki.home"),
           "crossing flush_events via turn events alone must trigger maintain (wiki home rebuild is observable)"
  end

  # ---- sessizlik + knob + sabit pin'leri ------------------------------------

  def test_turn_subscription_is_silent_and_outside_wake_kinds
    spy = SpyBus.new
    h = harness(store, event_bus: spy)
    h.start!
    h.enqueue_event(:turn, turn_event)
    assert h.wait_idle
    h.shutdown

    assert_empty spy.posts, "the chronicler must never post/emit anything on the bus (silence contract)"
    assert_includes spy.subscriptions, :turn_finished
    refute_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :turn_finished,
                    "turn finish must stay outside WAKE_KINDS — the chronicler never wakes the maestro"
  end

  def test_root_turns_false_skips_the_turn_subscription_entirely
    spy = SpyBus.new
    h = harness(store, event_bus: spy, config: { "subagents.vakanuvis.root_turns" => false })
    h.start!
    h.shutdown

    assert_equal [:subagent_completed, :goal_finished], spy.subscriptions,
                 "root_turns=false must leave only the K3 doors subscribed"
  end

  def test_turn_event_literals_are_pinned_to_the_vocabulary_homes
    assert_equal :turn_finished, Rubik::REPL::TurnRecorder::TURN_EVENT_TARGET
    assert_equal Rubik::REPL::TurnRecorder::TURN_EVENT_TARGET,
                 Rubik::Storage::Vakanuvis::Harness::TURN_EVENT
  end

  # ---- determinizm replay ---------------------------------------------------

  def replay(dir_name)
    root = File.join(@root, dir_name)
    Dir.mkdir(root)
    s = Rubik::Storage::Store.new(root: root, project: "Replay")
    h = Rubik::Storage::Vakanuvis::Harness.new(store: s, session_slug: "replay")
    h.start!
    h.enqueue_event(:turn, turn_event(prompt: "first question", outcome: "answered"))
    h.enqueue_event(:turn, turn_event(kind: "failed", prompt: "second", outcome: "boom", tokens: nil))
    h.enqueue_event(:subagent, { id: "s1", role: "Coder", state: "completed",
                                 storage_id: "s1-abc", max_steps: 10 })
    h.enqueue_event(:turn, turn_event(prompt: "third", outcome: "wrapped up"))
    assert h.wait_idle
    h.shutdown
    ["note", "wiki"].to_h { |t| [t, s.list(type: t).map { |row| s.get(type: t, id: row.id).except("created_at", "updated_at", "version") }] }
                    .merge("refs" => s.refs)
  end

  def test_turn_mixed_sequence_replays_to_identical_store_snapshot
    first = replay("run-a")
    second = replay("run-b")
    assert_equal first, second,
                 "turn+subagent sequence must replay byte-identically (timestamps/version aside) — determinism contract"
  end

  # ---- emisyon düzlemi (TurnRecorder) --------------------------------------

  class EmitHost
    include Rubik::REPL::TurnRecorder

    def initialize(bus, config = {})
      @event_bus = bus
      @config = config
      @conversation_history = []
      @recorder = nil
    end
  end

  def test_emit_turn_finished_posts_the_deterministic_payload
    spy = SpyBus.new
    EmitHost.new(spy).emit_turn_finished(kind: :success, prompt: "p", outcome: "o",
                                         orchestrator: nil, tokens: 7)
    name, payload, kwargs = spy.posts.first
    assert_equal :turn_finished, name
    assert_equal({ kind: "success", prompt: "p", outcome: "o", tools: "", tokens: 7 }, payload)
    assert_equal :repl, kwargs[:subsystem]
  end

  # CRITICAL regresyon kilidi (review bulgusu): Hash token sayacı (Loop'ün
  # gerçek şekli) olayı düşürmez — üretici skalerler, satır yazar.
  def test_emit_turn_finished_scalarizes_the_hash_token_counter
    spy = SpyBus.new
    EmitHost.new(spy).emit_turn_finished(kind: "success", prompt: "p", outcome: "o",
                                         tokens: { input: 1000, output: 40 })
    assert_equal 1040, spy.posts.first[1][:tokens]

    _key, line = Rubik::Storage::Vakanuvis::AnnalWriter.turn_line(
      1, 1, { kind: "success", prompt: "p", outcome: "o", tools: "", tokens: { input: 10, output: 5 } }
    )
    assert_includes line, "tokens=15", "turn_line must survive a raw Hash counter alone (defense in depth)"

    # Deeper degenerate shape: non-Numeric members are silently excluded,
    # never crash the line (review residual — "line never drops" is unconditional).
    _k2, deep = Rubik::Storage::Vakanuvis::AnnalWriter.turn_line(
      2, 2, { kind: "failed", prompt: "p", outcome: "o", tools: "", tokens: { input: 7, junk: { deep: 1 } } }
    )
    assert_includes deep, "tokens=7"
  end

  def test_emit_turn_finished_carries_the_activity_tool_tally
    spy = SpyBus.new
    activity = Rubik::Orchestrator::ActivityLog.new
    activity.record("storage", {}, :ok)
    activity.record("read_file", {}, :ok)
    activity.record("read_file", {}, :ok)
    orch = Struct.new(:activity).new(activity)
    EmitHost.new(spy).emit_turn_finished(kind: "success", prompt: "p", outcome: "o", orchestrator: orch)
    assert_equal "read_file(x2) storage(x1)", spy.posts.first[1][:tools]
  end

  def test_emit_turn_finished_without_a_bus_is_a_noop
    EmitHost.new(nil).emit_turn_finished(kind: "success", prompt: "p", outcome: "o")
  end

  def test_emit_turn_finished_rescues_a_broken_bus
    broken = Object.new
    def broken.post(*)
      raise "bus exploded"
    end

    EmitHost.new(broken).emit_turn_finished(kind: "success", prompt: "p", outcome: "o")
  end

  def test_record_failed_turn_emits_kind_failed_and_respects_the_logging_knob
    spy = SpyBus.new
    host = EmitHost.new(spy, "context.log_failed_turns" => true)
    host.record_failed_turn!("do the thing", "failed", "no LLM provider available", nil)

    name, payload, = spy.posts.first
    assert_equal :turn_finished, name
    assert_equal "failed", payload[:kind]
    assert_includes payload[:outcome], "[Turn failed: no LLM provider available]"
    assert_equal "do the thing", payload[:prompt]

    silenced = SpyBus.new
    EmitHost.new(silenced, "context.log_failed_turns" => false)
            .record_failed_turn!("do the thing", "failed", "reason", nil)
    assert_empty silenced.posts, "log_failed_turns=false suppresses the chronicle too (R9, least surprise)"
  end

  # ---- ActivityLog#tool_tally ----------------------------------------------

  def test_activity_log_tool_tally_is_alphabetical_bounded_and_deterministic
    log = Rubik::Orchestrator::ActivityLog.new
    assert_equal "", log.tool_tally

    log.record("read_file", {}, :ok)
    log.record("read_file", {}, :ok)
    log.record("storage", {}, :ok)
    assert_equal "read_file(x2) storage(x1)", log.tool_tally

    tall = Rubik::Orchestrator::ActivityLog.new
    ("a".."h").each { |t| tall.record(t, {}, :ok) }
    assert_equal 6, tall.tool_tally.split.size, "max_tools caps the tally at six entries"
    assert_equal "a(x1) b(x1) c(x1) d(x1) e(x1) f(x1)", tall.tool_tally
  end
end
