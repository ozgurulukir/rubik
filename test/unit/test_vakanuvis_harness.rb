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
    store_obj.get(type: "note", id: Rubik::Storage::Vakanuvis::Vocabulary.session_ref(SLUG))
  end

  # ---- annal + ref hijyeni -----------------------------------------------

  def test_subagent_event_writes_session_annal_with_ref_and_deterministic_line
    h = harness
    h.start!
    h.enqueue_event(:subagent, subagent_event)
    assert h.wait_idle, "worker should drain the queue"
    h.shutdown

    annal = session_annal(h.store)
    assert annal, "session annal must exist via ref #{Rubik::Storage::Vakanuvis::Vocabulary.session_ref(SLUG)}"
    assert_equal "note", annal["type"]
    assert_includes annal["body"], "subagent subagent-1-abc role=Coder state=completed"
    assert_includes annal["body"], "(event=subagent.subagent-1-abc.completed)"
    assert_equal annal["id"], h.store.refs[Rubik::Storage::Vakanuvis::Vocabulary.session_ref(SLUG)],
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
    assert_equal [:subagent_completed, :goal_finished, :turn_finished], spy.subscriptions
    refute_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :goal_finished,
                    "goal finish must stay outside WAKE_KINDS — the chronicler never wakes the maestro"
    refute_includes Rubik::REPL::Lifecycle::WAKE_KINDS, :turn_finished,
                    "turn finish must stay outside WAKE_KINDS — the chronicler never wakes the maestro"
  end

  def test_event_literals_are_pinned_to_the_vocabulary_homes
    assert_equal Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
                 Rubik::Storage::Vakanuvis::Harness::SUBAGENT_EVENT
    assert_equal Rubik::Orchestrator::GoalState::FINISH_EVENT,
                 Rubik::Storage::Vakanuvis::Harness::GOAL_EVENT
    assert_equal Rubik::REPL::TurnRecorder::TURN_EVENT_TARGET,
                 Rubik::Storage::Vakanuvis::Harness::TURN_EVENT
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

  def test_exact_recall_excludes_forgotten_memory_and_retired_wiki
    h = harness
    h.record(topic: "retired fact", body: "alpha beta")
    h.forget(ref: "mem.retired-fact")
    h.store.put(type: "wiki", title: "retired page", body: "alpha beta", status: "superseded")
    active = h.store.put(type: "wiki", title: "Current", body: "alpha beta")

    result = h.recall("alpha beta")
    assert_includes result, active["id"]
    refute_includes result, "retired fact"
    refute_includes result, "retired page"
  end

  def test_shutdown_cannot_overtake_an_admitted_event
    h = harness
    h.start!
    paused = Queue.new
    release = Queue.new
    queue = h.instance_variable_get(:@queue)
    queue.define_singleton_method(:push) do |item|
      unless item == Rubik::Storage::Vakanuvis::Harness::STOP
        paused.push(true)
        release.pop
      end
      super(item)
    end
    producer = Thread.new { h.enqueue_event(:subagent, subagent_event) }
    Timeout.timeout(2) { paused.pop }
    shutdown_started = Queue.new
    closer = Thread.new do
      shutdown_started.push(true)
      h.shutdown
    end
    Timeout.timeout(2) do
      shutdown_started.pop
      Thread.pass while closer.alive? && closer.status != "sleep"
    end
    release.push(true)
    assert producer.join(2), "enqueue must finish"
    assert closer.join(3), "shutdown must finish"
    assert producer.value
    assert_equal 0, h.queue_size
    refute h.busy?
    assert session_annal(h.store), "admitted event must be processed before STOP"
    refute h.enqueue_event(:subagent, subagent_event)
  ensure
    release&.push(true)
    producer&.join(2)
    closer&.join(3)
    h&.shutdown unless h&.stopped?
  end

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

  # ---- Auto-digest touched topics (issue #341) ------------------------------

  def test_record_tracks_touched_topics
    h = harness
    h.record(topic: "authentication flow", body: "Tokens and cookies.")
    assert_equal ["authentication flow"], h.touched_topics
  end

  def test_goal_finish_auto_digests_touched_topics
    s = store
    h = harness(s)
    h.start!
    h.record(topic: "Topic Alpha", body: "Alpha details.")
    h.record(topic: "Topic Beta", body: "Beta details.")
    h.enqueue_event(:goal, goal_event(goal: "ship alpha beta"))
    assert h.wait_idle, "worker should process goal event"

    status = h.digest_status
    assert_includes status, "wiki.topic-alpha"
    assert_includes status, "wiki.topic-beta"
    assert_empty h.touched_topics, "touched topics must be drained after auto-digest"
    h.shutdown
  end

  def test_repeated_maintain_does_not_requeue_unchanged_topics
    s = store
    h = harness(s)
    h.record(topic: "Idempotent Topic", body: "Content.")
    h.send(:maintain, goal_end: true)
    queued_after_first = h.gate.job_targets[:queued]
    h.send(:maintain, goal_end: true)
    queued_after_second = h.gate.job_targets[:queued]

    assert_equal queued_after_first, queued_after_second, "repeated maintain must not re-queue unchanged topics"
  end

  def test_auto_digest_disabled_when_config_false_or_distiller_false
    cfg_no_auto = Rubik::Config.new(root_dir: @root, home_dir: @root)
    cfg_no_auto.set("subagents.vakanuvis.auto_digest", false, persist: false)
    h_no_auto = harness(store, config: cfg_no_auto)
    h_no_auto.record(topic: "Silent Topic", body: "No auto digest.")
    h_no_auto.send(:maintain, goal_end: true)

    assert_equal 0, h_no_auto.gate.job_targets[:queued].size
    assert_equal 0, h_no_auto.gate.job_targets[:in_flight].size

    cfg_no_dist = Rubik::Config.new(root_dir: @root, home_dir: @root)
    cfg_no_dist.set("subagents.vakanuvis.distiller", false, persist: false)
    h_no_dist = harness(store, config: cfg_no_dist)
    h_no_dist.record(topic: "Dormant Topic", body: "Distiller off.")
    h_no_dist.send(:maintain, goal_end: true)

    assert_equal 0, h_no_dist.gate.job_targets[:queued].size
    assert_equal 0, h_no_dist.gate.job_targets[:in_flight].size
  end

  def test_shutdown_auto_digests_without_spawning_and_tears_down_promptly
    s = store
    h = harness(s)
    10.times { |i| h.record(topic: "Topic #{i}", body: "Body for topic #{i}.") }
    h.start!

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    h.shutdown
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert elapsed < 2.5, "shutdown (worker join included) must stay well under the 2s join budget + slack, took #{elapsed}s"
    assert h.stopped?
    assert_equal 10, h.gate.job_targets[:queued].size
    assert_equal 0, h.gate.job_targets[:in_flight].size, "shutdown must not spawn distillers into in-flight"
  end

  # ---- Auto-digest error isolation + honest shutdown (review of #346) -------

  class StoreBoom < StandardError; end

  class DmesgSpy
    attr_reader :entries

    def initialize
      @entries = []
    end

    def log(_subsystem, level, message) = @entries << [level, message]
  end

  def test_auto_digest_submit_failure_isolates_remaining_topics_and_rearms
    h = harness
    h.record(topic: "Good Topic", body: "Compiles fine.")
    h.record(topic: "Bad Topic", body: "Explodes.")
    h.record(topic: "Later Topic", body: "Must survive.")

    submitted = []
    h.gate.stub(:submit_with_status, lambda { |topic, spawn:|
      raise StoreBoom, "transcript list exploded" if topic == "Bad Topic"

      submitted << [topic, spawn]
      ["receipt", :accepted]
    }) do
      refute h.send(:auto_digest_touched!), "a stranded topic must not report full success"
    end

    assert_equal [["Good Topic", true], ["Later Topic", true]], submitted,
                 "a failing submit must not abort the remaining topics"
    assert_equal ["Bad Topic"], h.touched_topics, "failed topic must be re-armed for the next flush point"
  end

  def test_auto_digest_capacity_refusal_is_rearmed_not_lost
    spy = DmesgSpy.new
    cfg = Rubik::Config.new(root_dir: @root, home_dir: @root)
    cfg.set("subagents.vakanuvis.max_digest_jobs", 1, persist: false)
    h = harness(store, config: cfg, dmesg: spy)
    h.record(topic: "Queued Topic", body: "Takes the only slot.")
    h.send(:auto_digest_touched!)

    h.record(topic: "Refused Topic", body: "Finds the gate full.")
    refute h.send(:auto_digest_touched!), "capacity refusal must not report full success"
    assert_equal ["wiki.queued-topic"], h.gate.job_targets[:queued]
    assert_equal ["Refused Topic"], h.touched_topics, "refused topic must be re-armed, not silently dropped"
    assert spy.entries.any? { |level, msg| level == :warn && msg.include?("auto-digest refused for 'Refused Topic'") },
           "the refusal must be logged with the topic name when it happens"
  end

  def test_shutdown_survives_an_auto_digest_crash_and_still_tears_down_the_worker
    spy = DmesgSpy.new
    h = harness(store, dmesg: spy)
    h.start!
    h.stub(:auto_digest_touched!, ->(**) { raise StoreBoom, "unexpected explosion" }) do
      h.shutdown
    end

    assert h.stopped?
    assert_nil h.instance_variable_get(:@worker), "worker join/kill must run despite the auto-digest failure"
    assert spy.entries.any? { |level, msg| level == :warn && msg.include?("shutdown auto-digest failed") },
           "the crash must be logged, not swallowed"
  end

  def test_shutdown_logs_parked_topics_honestly
    spy = DmesgSpy.new
    h = harness(store, dmesg: spy)
    h.record(topic: "Parked One", body: "b")
    h.record(topic: "Parked Two", body: "c")
    h.shutdown

    parked = spy.entries.any? { |_level, msg| msg.include?("queued but not spawned") && msg.include?("Parked One") && msg.include?("Parked Two") }
    assert parked, "shutdown must honestly log parked (queued, unspawned) touched topics"
  end
end
