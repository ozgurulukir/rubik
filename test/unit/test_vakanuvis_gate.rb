# frozen_string_literal: true

require_relative "../test_helper"

# DistillGate::Gate — damıtıcı doğum kapısının durumlu yarısı (kuyruk +
# doğum sicili + kirli işaret). Burada iki kilit değişmezi kilitlenir:
# (1) submit'ın dedupe+itmesi TEK @lock bölümünde, doğum denemesi AYRI
# pencerede (iki fazlı — TOCTOU düzeltmesi korunur); (2) completion_event
# sicilden silip kilidi BIRAKIR, supervisor.get + hasat kilit dışı
# kurtarma bölgesinde koşar (crash'te hedefli iş geri konur). Makbuz
# dizgileri bayt-bayt eski Harness#digest çıktısıdır.
class TestVakanuvisGate < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_vakanuvis_gate")
    @store = Rubik::Storage::Store.new(root: @root, project: "gate")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  # Deterministik supervisor ikizi (distiller süitinin ikiziyle aynı sözleşme).
  class FakeSup
    attr_reader :spawn_calls

    def initialize(result: nil, types_present: true, raise_on_spawn: false, type_registry: nil)
      @result = result
      @types_present = types_present
      @raise_on_spawn = raise_on_spawn
      @type_registry = type_registry
      @spawn_calls = []
      @instances = {}
    end

    def type_registry
      return @type_registry if @type_registry

      registry = Object.new
      present = @types_present
      registry.define_singleton_method(:get) { |name| present && name == "vakanuvis" ? :defined : nil }
      registry
    end

    def spawn(role:, prompt:, type_name:, max_steps:, model:, parent_id: "agent-0")
      @spawn_calls << { role: role, prompt: prompt, type_name: type_name, parent_id: parent_id,
                        max_steps: max_steps, model: model }
      raise "supervisor unavailable" if @raise_on_spawn

      inst = Struct.new(:id, :result).new("subagent-distill-#{@spawn_calls.size}", @result)
      @instances[inst.id] = inst
      inst
    end

    def get(id) = @instances[id]
  end

  class BusSpy
    def subscribe(_name, _context = nil, &) = yield
  end

  class DmesgSpy
    attr_reader :warnings

    def initialize = @warnings = []

    def log(_subsystem, level, message)
      @warnings << message if level == :warn
    end
  end

  def gate(supervisor: FakeSup.new, enabled: true, dmesg: nil)
    Rubik::Storage::Vakanuvis::DistillGate::Gate.new(
      store: @store, supervisor: supervisor, event_bus: BusSpy.new,
      enabled: enabled, max_steps: 8, session_slug: "gate-suite", dmesg: dmesg
    )
  end

  def completion(inst_id, state: "completed")
    { id: inst_id, role: "Vakanüvis Distiller", state: state, storage_id: "#{inst_id}-x", max_steps: 8 }
  end

  # ---- Seam 1: submit --------------------------------------------------------

  def test_submit_queues_one_job_and_the_receipt_names_the_deterministic_target
    sup = FakeSup.new(result: "wiki.release-pipeline\n# Release pipeline\nGates then tag then push. Sources: the annal.\n")
    g = gate(supervisor: sup)
    receipt = g.submit("release pipeline")

    assert_includes receipt, "wiki.release-pipeline", "the receipt names the deterministic target"
    assert_includes receipt, "did NOT wait for the LLM", "spawned path: the receipt promises the async compile"
    assert_equal 1, sup.spawn_calls.size
    call = sup.spawn_calls.first
    assert_equal "vakanuvis", call[:type_name]
    assert_includes call[:prompt], "Target ref (your first line MUST be exactly this): wiki.release-pipeline"
    assert_equal({ batch: true }, g.peek_job(batch: true),
                 "after a successful spawn the confirmed job left the queue — peek falls back to the batch sentinel")
  end

  def test_second_submit_for_an_in_flight_target_is_refused_with_the_already_queued_receipt
    sup = FakeSup.new(result: "wiki.dupe-topic\n# Dupe\nBody long enough to pass the gate.\n")
    g = gate(supervisor: sup)
    first = g.submit("dupe topic")
    second = g.submit("dupe topic")

    assert_includes first, "did NOT wait for the LLM"
    assert_includes second, "already queued", "an in-flight target dedupes to an honest receipt"
    assert_equal 1, sup.spawn_calls.size, "no double spawn for the same target"
  end

  def test_session_profile_cleanup_preserves_vakanuvis_harness_lookup
    context = Rubik::Runtime::Context.new
    registry = Rubik::Orchestrator::Subagent::TypeRegistry.new(default_context: context)
    registry.define_custom(name: "temporary_scout", description: "Temporary", system_prompt: "Inspect.")
    context.dispose

    sup = FakeSup.new(result: "wiki.release-pipeline\n# Release pipeline\nGates then tag then push. Sources: the annal.\n",
                      type_registry: registry)
    assert_equal "vakanuvis", registry.get("vakanuvis").name
    assert_nil registry.get("temporary_scout")
    receipt = gate(supervisor: sup).submit("release pipeline")

    assert_includes receipt, "did NOT wait for the LLM"
    assert_equal "vakanuvis", sup.spawn_calls.first[:type_name]
  ensure
    context&.dispose unless context&.disposed?
  end

  # ---- Seam 2: completion_event ----------------------------------------------

  def test_completion_event_requeues_a_targeted_job_when_the_run_ends_incomplete
    g = gate(supervisor: FakeSup.new(result: nil)) # result yok — koşu 'failed' bitmiş gibi
    g.submit("precious query")
    outcome = g.completion_event(completion("subagent-distill-1", state: "failed"))

    assert_equal :incomplete, outcome
    assert_equal "wiki.precious-query", g.peek_job(batch: false)[:target],
                 "a failed run must return the digest job to the queue — the receipt's promise survives"
  end

  def test_completion_event_requeues_the_job_when_harvest_crashes_mid_write
    crashing = FakeSup.new(result: "wiki.x\n# Page\nbody that is long enough to pass the length gate.\n")
    def crashing.get(_id) = raise("store IO exploded during harvest")

    spy = DmesgSpy.new
    g = gate(supervisor: crashing, dmesg: spy)
    g.submit("any topic")
    outcome = g.completion_event(completion("subagent-distill-1"))

    assert_equal :crashed, outcome
    assert_equal "wiki.any-topic", g.peek_job(batch: false)[:target],
                 "review fix: a harvest crash must REQUEUE the digest job — the receipt's promise survives"
    assert(spy.warnings.any? { |w| w.include?("harvest crashed") && w.include?("digest requeued") },
           "the crash is logged through the gate's own dmesg")
  end

  # ---- Seam 3: flush_tick (v2 §4-V5 dirty mark) -------------------------------

  def test_flush_tick_spawns_a_batch_compile_only_when_durable_content_changed
    sup = FakeSup.new(result: "wiki.chosen-by-model\n# Page\nCompiled from the annal with enough body text.\n")
    g = gate(supervisor: sup)

    inst = g.flush_tick
    refute_nil inst, "an unsnapshotted gate is born dirty — the first flush may compile"
    assert_equal :compiled, g.completion_event(completion(inst.id)) # harvest → mark_compiled!

    assert_nil g.flush_tick, "with a clean snapshot, idle flushing spawns nothing"
    @store.put(type: "memory", title: "fresh card", body: "a durable lesson")
    refute_nil g.flush_tick, "new durable content re-dirties the mark"
  end

  def test_same_topic_memory_update_redirties_compile
    steward = Rubik::Storage::Vakanuvis::MemorySteward
    first = steward.record(@store, topic: "same", body: "first durable lesson")
    g = gate
    g.mark_compiled!
    assert_nil g.flush_tick

    updated = steward.record(@store, topic: "same", body: "updated durable lesson")
    assert_equal first["id"], updated["id"]
    refute_nil g.flush_tick
  end

  def test_same_ref_wiki_update_redirties_compile
    v = Rubik::Storage::Vakanuvis
    first = v.upsert(@store, type: "wiki", ref: "wiki.same", title: "Same", body: "first page")
    g = gate
    g.mark_compiled!
    assert_nil g.flush_tick

    updated = v.upsert(@store, type: "wiki", ref: "wiki.same", title: "Same", body: "updated page")
    assert_equal first["id"], updated["id"]
    refute_nil g.flush_tick
  end

  def test_existing_note_update_redirties_compile
    note = @store.put(type: "note", title: "Durable", body: "first lesson")
    g = gate
    g.mark_compiled!
    @store.put(type: "note", id: note["id"], title: "Durable", body: "updated lesson")
    refute_nil g.flush_tick
  end

  def test_turn_only_annal_appends_stay_clean_but_other_annal_events_redirty
    v = Rubik::Storage::Vakanuvis
    writer = v::AnnalWriter
    ref = v::Vocabulary.session_ref("gate-suite")
    writer.append(@store, ref: ref, title: "Session", lines: [writer.turn_line(1, 1, { kind: "success" })])
    g = gate
    g.mark_compiled!
    writer.append(@store, ref: ref, title: "Session", lines: [writer.turn_line(2, 2, { kind: "success" })])
    assert_nil g.flush_tick

    writer.append(@store, ref: ref, title: "Session", lines: [["subagent.x.completed", "- subagent x (event=subagent.x.completed)"]])
    refute_nil g.flush_tick
  end

  # ---- peek_job: salt-okunur test yüzeyi --------------------------------------

  def test_peek_job_shows_the_queue_head_without_consuming_it
    g = gate(supervisor: FakeSup.new(types_present: false)) # spawn kapalı — iş kuyrukta kalır
    g.submit("peeked topic")

    job = g.peek_job(batch: false)
    assert_equal "wiki.peeked-topic", job[:target]
    assert_equal job, g.peek_job(batch: false), "peek does not consume"
    assert_equal job, g.peek_job(batch: true), "a queued targeted job outranks the batch sentinel"

    empty = gate(supervisor: FakeSup.new)
    assert_nil empty.peek_job(batch: false), "an empty queue peeks nil"
    assert_equal({ batch: true }, empty.peek_job(batch: true), "batch peek answers the sentinel on an empty queue")
  end

  def test_job_targets_reports_queued_and_in_flight_targets
    sup = FakeSup.new(result: "wiki.status-topic\n# Status\nBody long enough to pass the gate.\n")
    g = gate(supervisor: sup)
    assert_equal({ queued: [], in_flight: [] }, g.job_targets, "an idle gate reports empty on both sides")

    g.submit("status topic")
    assert_equal({ queued: [], in_flight: ["wiki.status-topic"] }, g.job_targets,
                 "a spawned digest is in flight, not queued")

    g.completion_event(completion("subagent-distill-1"))
    assert_equal({ queued: [], in_flight: [] }, g.job_targets, "a compiled digest leaves the registry")
  end

  def test_job_targets_keeps_a_disabled_spawn_job_queued
    g = gate(supervisor: FakeSup.new(types_present: false))
    g.submit("parked topic")
    assert_equal({ queued: ["wiki.parked-topic"], in_flight: [] }, g.job_targets,
                 "a digest that cannot spawn stays visible as queued")
  end

  # ---- doğum kapalı: iş kuyrukta kalır, makbuz dürüst -------------------------

  def test_spawn_disabled_keeps_the_job_queued_and_receipt_honest
    missing_type = gate(supervisor: FakeSup.new(types_present: false))
    receipt = missing_type.submit("never compiled")
    assert_includes receipt, "No distiller run started yet", "receipt must be honest about the unavailable distiller"
    assert_equal "wiki.never-compiled", missing_type.peek_job(batch: true)[:target],
                 "the digest job stays queued — an unavailable distiller loses nothing"

    knob_off = gate(enabled: false)
    receipt = knob_off.submit("also never compiled")
    assert_includes receipt, "No distiller run started yet"
    assert_equal "wiki.also-never-compiled", knob_off.peek_job(batch: true)[:target]
  end

  def test_spawn_exception_requeues_the_claimed_digest_job
    supervisor = FakeSup.new(raise_on_spawn: true)
    g = gate(supervisor: supervisor)
    receipt = g.submit("retry after spawn failure")

    assert_includes receipt, "No distiller run started yet"
    assert_equal "wiki.retry-after-spawn-failure", g.peek_job(batch: false)[:target]
    assert_equal 1, supervisor.spawn_calls.size
  end

  # ---- yapısal sözleşme: Gate, Harness'e geri dokunmaz ------------------------

  def test_gate_never_calls_back_into_the_harness
    params = Rubik::Storage::Vakanuvis::DistillGate::Gate.instance_method(:initialize).parameters
    assert params.any?, "the constructor has parameters"
    assert params.all? { |(kind, _name)| [:keyreq, :key].include?(kind) },
           "constructor is keyword-only — no positional harness object injection"
    refute params.any? { |(_kind, name)| name == :harness },
           "no harness keyword: Gate is fed store/supervisor/strings, never its owner"
  end
end
