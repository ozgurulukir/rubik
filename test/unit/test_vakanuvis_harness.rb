# frozen_string_literal: true

require_relative "../test_helper"

# Vakanüvis Düzlem 1 (deterministik kronikçi çekirdeği) — plan
# 2026-10-04 §4.7 test sözleşmesi: annal upsert + ref hijyeni, kuyruk
# taşması (drop-oldest + annal izi), determinizm replay (aynı olay dizisi
# ⇒ aynı depo anlık görüntüsü, timestamp/version hariç), sessizlik
# (WAKE_KINDS dışı; kronikçi bus'a hiçbir şey yaymaz), retention
# supersede/purge (K2) ve goal bitiş kancası (GoalState::FINISH_EVENT).
class TestVakanuvisHarness < Minitest::Test
  SLUG = "test-session-42"

  def setup
    @root = Dir.mktmpdir("rubik_vakanuvis")
    # Bu süit Service.bind'i gerçekten bağlar — test zırhını (RUBIK_TEST)
    # force ile devre dışı bırakır, teardown eski haline koyar.
    @force_before = ENV.fetch("RUBIK_VAKANUIS_FORCE", nil)
    ENV["RUBIK_VAKANUIS_FORCE"] = "1"
  end

  def teardown
    ENV["RUBIK_VAKANUIS_FORCE"] = @force_before
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def store
    Rubik::Storage::Store.new(root: @root, project: "Vakanuvis Test")
  end

  def harness(store_obj = store, **)
    Rubik::Storage::Vakanuvis::Harness.new(store: store_obj, session_slug: SLUG, **)
  end

  def subagent_event(id: "subagent-1", storage_id: "subagent-1-abc", role: "Coder", state: "completed")
    { id: id, role: role, state: state, storage_id: storage_id, max_steps: 10 }
  end

  def goal_event(goal: "ship the release", status: "completed", steps: 12, max_steps: 100, last_error: "")
    { status: status, goal: goal, steps: steps, max_steps: max_steps, output_summary: "done", last_error: last_error }
  end

  def session_annal(store_obj)
    store_obj.get(type: "note", id: Rubik::Storage::Vakanuvis::AnnalWriter.session_ref(SLUG))
  end

  # ---- annal + ref hijyeni -----------------------------------------------

  def test_subagent_event_writes_session_annal_with_ref_and_deterministic_line
    h = harness
    h.start!
    h.enqueue_event(:subagent, subagent_event)
    assert h.wait_idle, "worker should drain the queue"
    h.shutdown

    annal = session_annal(h.store)
    assert annal, "session annal must exist via ref #{Rubik::Storage::Vakanuvis::AnnalWriter.session_ref(SLUG)}"
    assert_equal "note", annal["type"]
    assert_includes annal["body"], "subagent subagent-1-abc role=Coder state=completed"
    assert_includes annal["body"], "(event=subagent.subagent-1-abc.completed)"
    assert_equal annal["id"], h.store.refs[Rubik::Storage::Vakanuvis::AnnalWriter.session_ref(SLUG)],
                 "ref must be bound to the annal row (ref hygiene)"
    refute_includes annal["body"], Time.now.year.to_s, "annal lines carry no wall clock — pure event data"
  end

  def test_event_redelivery_is_deduplicated_and_version_frozen
    h = harness
    h.start!
    h.enqueue_event(:subagent, subagent_event)
    h.enqueue_event(:subagent, subagent_event(storage_id: "subagent-2-xyz"))
    assert h.wait_idle
    settled = session_annal(h.store)
    lines_before = settled["body"].lines.size

    h.enqueue_event(:subagent, subagent_event) # yeniden teslim: aynı anahtar
    assert h.wait_idle
    h.shutdown

    second = session_annal(h.store)
    assert_equal lines_before, second["body"].lines.size, "redelivered event must not append a duplicate line"
    assert_equal settled["version"], second["version"], "unchanged content must skip the put entirely"
  end

  def test_goal_finish_writes_goal_annal_and_session_line
    h = harness
    h.start!
    h.enqueue_event(:goal, goal_event(goal: "make tests green"))
    assert h.wait_idle
    h.shutdown

    goal_annal = h.store.get(type: "note", id: "annal.goal.1")
    assert goal_annal, "goal annal must exist via ref annal.goal.1"
    assert_includes goal_annal["body"], "goal: make tests green"
    assert_includes goal_annal["body"], "status=completed steps=12/100"
    assert_includes session_annal(h.store)["body"], "(event=goal.1.completed)"
    assert_equal goal_annal["id"], h.store.refs["annal.goal.1"]

    h2 = harness(h.store, session_slug: SLUG)
    h2.start!
    h2.enqueue_event(:goal, goal_event(goal: "second run", status: "failed", steps: 3, last_error: "boom"))
    assert h2.wait_idle
    h2.shutdown
    assert h.store.get(type: "note", id: "annal.goal.2"), "goal ordinal must increment per goal event"
  end

  # ---- determinizm replay --------------------------------------------------

  def snapshot(store_obj)
    out = {}
    ["note", "memory", "wiki"].each do |type|
      out[type] = store_obj.list(type: type).map do |s|
        rec = store_obj.get(type: type, id: s.id)
        rec.except("created_at", "updated_at", "version")
      end
    end
    out["refs"] = store_obj.refs
    out
  end

  def replay(dir_name)
    root = File.join(@root, dir_name)
    Dir.mkdir(root)
    s = Rubik::Storage::Store.new(root: root, project: "Replay")
    h = Rubik::Storage::Vakanuvis::Harness.new(store: s, session_slug: "replay")
    h.start!
    h.enqueue_event(:subagent, subagent_event(storage_id: "subagent-1-aa", role: "Research"))
    h.enqueue_event(:subagent, subagent_event(storage_id: "subagent-2-bb", role: "Coder", state: "failed"))
    h.enqueue_event(:goal, goal_event(goal: "deterministic replay"))
    h.enqueue_event(:subagent, subagent_event(storage_id: "subagent-3-cc"))
    assert h.wait_idle
    h.shutdown
    snapshot(s)
  end

  def test_same_event_sequence_replays_to_identical_store_snapshot
    first = replay("run-a")
    second = replay("run-b")
    assert_equal first, second,
                 "same event sequence must produce byte-identical store state (timestamps/version aside) — determinism contract §4.2"
  end

  # ---- kuyruk taşması ------------------------------------------------------

  def test_queue_overflow_drops_oldest_and_notes_it_in_the_annal
    h = harness(max_queue: 5)
    8.times { |i| h.enqueue_event(:subagent, subagent_event(storage_id: "subagent-#{i}-s", role: "R#{i}")) }
    assert_equal 5, h.queue_size, "queue must hold at most max_queue events"
    h.start!
    assert h.wait_idle
    h.shutdown

    body = session_annal(h.store)["body"]
    assert_includes body, "3 event(s) dropped — queue overflow", "drop count must be chronicled"
    assert_includes body, "subagent-7-s", "newest events survive"
    refute_includes body, "subagent-0-s", "oldest events were dropped"
  end

  # ---- sessizlik (§4.3) ----------------------------------------------------

  class SpyBus
    attr_reader :posts, :subscriptions

    def initialize
      @posts = []
      @subscriptions = []
    end

    # context: — the dispatcher's subscribe signature; the spy ignores it.
    def subscribe(name, _context = nil, &blk)
      @subscriptions << name
      blk
    end

    def post(name, payload = {}, **kwargs)
      @posts << [name, payload, kwargs]
      true
    end

    def emit(name, payload = {}, **)
      post(name, payload, **)
    end
  end

  def test_chronicler_never_posts_to_the_bus_and_wakes_nobody
    spy = SpyBus.new
    h = harness(store, event_bus: spy)
    h.start!
    h.enqueue_event(:subagent, subagent_event)
    h.enqueue_event(:goal, goal_event)
    assert h.wait_idle
    h.shutdown

    assert_empty spy.posts, "the chronicler must never post/emit anything on the bus (silence contract)"
    assert_equal [:subagent_completed, :goal_finished], spy.subscriptions
    refute_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :goal_finished,
                    "goal finish must stay outside WAKE_KINDS — the chronicler never wakes the maestro"
  end

  def test_event_literals_are_pinned_to_the_vocabulary_homes
    assert_equal Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                 Rubik::Storage::Vakanuvis::Harness::SUBAGENT_EVENT
    assert_equal Rubik::Orchestrator::GoalState::FINISH_EVENT,
                 Rubik::Storage::Vakanuvis::Harness::GOAL_EVENT
  end

  def test_vakanuvis_sources_never_touch_the_notice_vocabulary
    Dir[File.expand_path("../../lib/rubik/storage/vakanuvis*", __dir__)]
      .select { |path| File.file?(path) }.each do |path|
      src = File.binread(path).force_encoding("UTF-8")
      refute_includes src, "Notices.emit", "#{path}: chronicler files must not emit notices"
      refute_includes src, "WAKE_KINDS", "#{path}: chronicler files must not reference wake kinds"
    end
  end

  # ---- retention (K2) -------------------------------------------------------

  def test_forget_supersede_leaves_a_trace_and_purge_deletes
    s = store
    h = harness(s)
    h.record(topic: "release checklist", body: "bump version, run gates, tag")

    superseded = h.forget(ref: "mem.release-checklist")
    assert superseded["forgot"]
    assert_equal "supersede", superseded["mode"]
    row = s.get(type: "memory", id: "mem.release-checklist")
    assert_equal "superseded", row["status"]
    assert_equal "forget", row["links"]["superseded_by"]

    # purge kolu doğrudan steward üzerinden (retention knob'u Config'siz)
    purged = Rubik::Storage::Vakanuvis::MemorySteward.forget(s, ref: "mem.release-checklist", retention: "purge")
    assert purged["forgot"]
    assert_equal "purge", purged["mode"]
    assert_nil s.get(type: "memory", id: "mem.release-checklist")
  end

  def test_forget_supersede_mode_keeps_the_row
    s = store
    h = harness(s)
    h.record(topic: "keep me", body: "value stays queryable")
    result = h.forget(ref: "mem.keep-me")
    assert_equal "supersede", result["mode"]
    refute_nil s.get(type: "memory", id: "mem.keep-me"), "supersede retention keeps the row as history"
  end

  # ---- Service.bind ---------------------------------------------------------

  def test_service_bind_disabled_returns_nil_and_happy_path_provides_coeffect
    root_ctx = Rubik::Runtime::Context.new
    root_ctx.provide(Rubik::Coeffects::STORAGE_STORE, store)

    disabled = Rubik::Config.new(root_dir: @root, home_dir: @root)
    disabled.set("subagents.vakanuvis.enabled", false, persist: false)
    assert_nil Rubik::Storage::Vakanuvis::Service.bind(root_ctx, config: disabled),
               "subagents.vakanuvis.enabled=false must not bind the chronicler"

    bound = Rubik::Storage::Vakanuvis::Service.bind(root_ctx, config: nil, event_bus: SpyBus.new)
    assert bound.is_a?(Rubik::Storage::Vakanuvis::Harness)
    assert_equal bound, root_ctx.get(Rubik::Coeffects::VAKANUIS)
    root_ctx.dispose
  end

  def test_service_bind_without_store_returns_nil
    root_ctx = Rubik::Runtime::Context.new
    assert_nil Rubik::Storage::Vakanuvis::Service.bind(root_ctx, config: nil)
    root_ctx.dispose
  end

  # Test zırhı: RUBIK_TEST ortamında kronikçi varsayılan bağlanmaz (gerçek
  # shell testlerinde arka plan doğumları yarış açmasın); FORCE env'i
  # kronikçinin kendi testleri için zırhı kaldırır.
  def test_service_enabled_test_armor
    ENV["RUBIK_VAKANUIS_FORCE"] = nil
    refute Rubik::Storage::Vakanuvis::Service.enabled?(nil), "RUBIK_TEST armor must default the chronicler off"

    ENV["RUBIK_VAKANUIS_FORCE"] = "1"
    assert Rubik::Storage::Vakanuvis::Service.enabled?(nil), "FORCE lifts the armor (K1 default on)"

    disabled = { "subagents" => { "vakanuvis" => { "enabled" => false } } }
    refute Rubik::Storage::Vakanuvis::Service.enabled?(disabled), "explicit operator off always wins"
  ensure
    ENV["RUBIK_VAKANUIS_FORCE"] = "1" # setup değeri; teardown gerçek eski haline koyar
  end

  # ---- GoalState kancası ----------------------------------------------------

  def test_goal_state_posts_finish_event_once
    spy = SpyBus.new
    gs = Rubik::Orchestrator::GoalState.new(event_bus: spy)
    gs.start!("do the thing", 50)
    gs.complete!("all green", tokens: { input: 10, output: 5 })
    gs.complete!("double finish is a no-op")

    assert_equal 1, spy.posts.size, "only the first finish may post"
    name, payload, = spy.posts.first
    assert_equal :goal_finished, name
    assert_equal "completed", payload[:status]
    assert_equal "do the thing", payload[:goal]
    assert_equal 50, payload[:max_steps]
  end

  def test_goal_state_without_bus_stays_silent_and_functional
    gs = Rubik::Orchestrator::GoalState.new
    gs.start!("legacy use", 5)
    gs.fail!("kaput")
    assert_equal :failed, gs.status
  end
end
