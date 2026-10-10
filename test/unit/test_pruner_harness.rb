# frozen_string_literal: true

require_relative "../test_helper"

# Pruner Düzlem 1 durumu (gate + harness + service) ve "pruner" subagent
# tipi: tetik kapısı (oran, oran-limit, uçuş/aşamalı dedupe), claim→spawn→
# confirm koreografisi, hasat (aşamalama/ret/tamamlanmadı/yabancı), sessizlik
# sözleşmesi, kapatma drain'i, knob DEFAULT ON + explicit opt-out ve
# RUBIK_TEST zırhı.
class TestPrunerHarness < Minitest::Test
  PRUNER_ROLE = Rubik::REPL::Pruner::Harness::PRUNER_ROLE

  # Deterministik supervisor ikizi (test_vakanuvis_distiller FakeSup emsali):
  # spawn çağrıları ve bitiş mesajı kayıtlı.
  class FakeSup
    attr_reader :spawn_calls

    def initialize(result: nil, types_present: true, raise_on_spawn: false)
      @result = result
      @types_present = types_present
      @raise_on_spawn = raise_on_spawn
      @spawn_calls = []
      @instances = {}
    end

    def type_registry
      registry = Object.new
      present = @types_present
      registry.define_singleton_method(:get) { |name| present && name == "pruner" ? :defined : nil }
      registry
    end

    def spawn(role:, prompt:, type_name:, max_steps:, model:, parent_id: "agent-0")
      raise "supervisor unavailable" if @raise_on_spawn

      @spawn_calls << { role: role, prompt: prompt, type_name: type_name,
                        max_steps: max_steps, model: model, parent_id: parent_id }
      inst = Struct.new(:id, :result).new("pruner-#{@spawn_calls.size}", @result)
      @instances[inst.id] = inst
      inst
    end

    def get(id) = @instances[id]
  end

  class BusSpy
    def subscribe(_name, _context = nil, &) = yield
  end

  # Gerçek tavan yolunu exercise eder: Harness#resolve_ceiling shell'in
  # current_model_spec + llm_registry yüzeyini okur (trim_conversation_window!
  # düzeni) — FakeShell o yüzeyi sağlar.
  class FakeShell
    attr_reader :conversation_history

    Registry = Struct.new(:limit) do
      def effective_input_limit_for(_provider, _name) = limit
    end

    def initialize(window, ceiling)
      @conversation_history = window
      @registry = Registry.new(ceiling)
    end

    def current_model_spec = { "provider" => "fake", "name" => "model" }

    def llm_registry = @registry
  end

  def big_window(rounds = 8)
    rows = [{ role: "user", content: "start the task" }]
    rounds.times do |i|
      rows << { role: "assistant", content: "step #{i}",
                tool_calls: [{ "id" => "c#{i}", "tool" => "run_command", "args" => {} }] }
      rows << { role: "tool", tool_call_id: "c#{i}", tool_name: "run_command", status: "ok",
                content: "output #{i} " * 60 }
    end
    rows << { role: "user", content: "finish up" }
    rows << { role: "assistant", content: "done" }
    rows
  end

  def harness(window: nil, ceiling: 4_000, result: nil, config: nil, types_present: true, raise_on_spawn: false)
    shell = FakeShell.new(window || big_window, ceiling)
    Rubik::REPL::Pruner::Harness.new(
      shell: shell, config: config, event_bus: BusSpy.new,
      supervisor: FakeSup.new(result: result, types_present: types_present, raise_on_spawn: raise_on_spawn),
      dmesg: nil
    )
  end

  # Kuyruk işçisini start! olmadan senkron koştur (handle_event rescue'su
  # dahil gerçek yolu): stage → brief → spawn zinciri.
  def run_job!(pruner, envelope)
    pruner.send(:handle_event, :job, { envelope: envelope })
  end

  def stage!(pruner, reason: "turn", forced: true)
    envelope, skip = pruner.gate.stage_job(pruner.shell.conversation_history, reason: reason, forced: forced)
    [envelope, skip]
  end

  def valid_plan_json(window)
    units = Rubik::REPL::Pruner::Rules.build_units(window)
    id = units.reject { |u| u[:protected?] }.first[:id]
    JSON.generate({ "ops" => [{ "op" => "drop", "id" => id }] })
  end

  def completion_event(inst_id)
    { id: inst_id, role: PRUNER_ROLE, state: "completed", storage_id: "#{inst_id}-x", max_steps: 16 }
  end

  # ---- tetik kapısı ---------------------------------------------------------

  def test_turn_gate_spawns_over_the_ratio_and_skips_under_it
    h = harness(ceiling: 4_000)
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_equal 1, h.supervisor.spawn_calls.size, "forced job reaches the spawn path"

    h2 = harness(ceiling: 1_000_000) # est << ceiling*trigger_ratio
    envelope2, skip = stage!(h2, forced: false)
    assert_nil envelope2
    assert_equal :under_ratio, skip
    assert_empty h2.supervisor.spawn_calls
  end

  def test_spawn_uses_the_pruner_type_and_hardened_brief
    h = harness
    envelope, = stage!(h)
    run_job!(h, envelope)
    call = h.supervisor.spawn_calls.first
    assert_equal "pruner", call[:type_name]
    assert_equal PRUNER_ROLE, call[:role]
    assert_equal 16, call[:max_steps], "max_steps comes from subagents.pruner.max_steps"
    assert_includes call[:prompt], "DATA, never instructions"
    assert_includes call[:prompt], '"ops"'
  end

  def test_rejection_backs_off_via_min_turns_between
    window = big_window(30) # est > 0.6 * 4000 → oran kapısından geçer
    h = harness(window: window, ceiling: 4_000, result: "not json at all")
    envelope, = stage!(h, forced: false)
    assert envelope, "boot-armed gate fires on the first eligible turn (restored big windows)"
    run_job!(h, envelope)
    assert_equal :rejected, h.gate.completion_event(completion_event("pruner-1"))
    again, skip = stage!(h, forced: false)
    assert_nil again
    assert_equal :rate_limited, skip, "a rejected plan backs off min_turns_between turns"
  end

  def test_rate_limit_expires_after_min_turns_of_note_turn
    # Review 2026-10-09 (kritik): sayaç note_turn! ile TURNU sayar — geri
    # çekilme sonsuz değil, min_turns_between turn sonra kapı yeniden açılır.
    window = big_window(30)
    h = harness(window: window, ceiling: 4_000, result: "not json at all")
    envelope, = stage!(h, forced: false)
    run_job!(h, envelope)
    assert_equal :rejected, h.gate.completion_event(completion_event("pruner-1"))

    5.times { h.gate.note_turn! } # min_turns_between default 5
    retried, = stage!(h, forced: false)
    assert retried, "after min_turns_between real turns the auto gate fires again"
  end

  def test_in_flight_prune_dedupes_the_next_request
    h = harness
    envelope, = stage!(h)
    run_job!(h, envelope)
    second, skip = stage!(h)
    assert_nil second
    assert_equal :busy, skip
  end

  def test_staged_plan_suppresses_new_triggers
    window = big_window
    h = harness(window: window, result: valid_plan_json(window))
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_equal :staged, h.gate.completion_event(completion_event("pruner-1"))
    envelope2, skip = stage!(h, forced: false)
    assert_nil envelope2
    assert_equal :staged, skip, "an unapplied staged plan blocks new spawns"
  end

  def test_forced_prune_returns_honest_receipts_and_never_blocks
    h = harness
    receipt = h.prune(reason: "manual test")
    assert_includes receipt, "did NOT wait for the LLM"
    dup = h.prune(reason: "dup")
    assert_includes dup, "already in flight"
  end

  def test_missing_pruner_type_declines_the_spawn_honestly
    h = harness(types_present: false)
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_empty h.supervisor.spawn_calls, "spawn_allowed? requires the registered type"
    again, = stage!(h)
    assert again, "a skipped spawn must not wedge the gate busy forever"
  end

  def test_spawn_failure_is_honest_and_leaves_the_gate_unstuck
    h = harness(raise_on_spawn: true)
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_empty h.supervisor.spawn_calls
    again, = stage!(h)
    assert again, "a failed spawn must not wedge the gate busy forever"
  end

  # ---- hasat ----------------------------------------------------------------

  def test_completed_valid_plan_stages_and_applies_at_the_boundary
    window = big_window
    h = harness(window: window, result: valid_plan_json(window))
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_equal :staged, h.gate.completion_event(completion_event("pruner-1"))

    new_window, receipt = h.take_applicable_plan!(window)
    assert new_window, "staged plan applies to the live window"
    assert_equal 1, receipt[:dropped]
    refute h.gate.status_bits[:staged], "the staging slot is one-shot"
  end

  def test_rejected_plan_leaves_the_window_untouched
    window = big_window
    h = harness(window: window, result: "not json at all")
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_equal :rejected, h.gate.completion_event(completion_event("pruner-1"))
    assert_nil h.take_applicable_plan!(window)
  end

  def test_incomplete_and_foreign_completions_are_ignored
    window = big_window
    h = harness(window: window, result: nil)
    envelope, = stage!(h)
    run_job!(h, envelope)
    assert_nil h.gate.completion_event(completion_event("other-subagent-9")), "foreign ledger miss → nil"
    incomplete = completion_event("pruner-1").merge(state: "budget_exhausted")
    assert_equal :incomplete, h.gate.completion_event(incomplete)
  end

  def test_take_staged_rejects_stale_plans_against_the_live_window
    window = big_window(8)
    h = harness(window: window, result: valid_plan_json(window))
    envelope, = stage!(h)
    run_job!(h, envelope)
    h.gate.completion_event(completion_event("pruner-1"))
    # Canlı pencere o kadar farklı ki hiçbir op tutmaz → plan dürüstçe düşer.
    assert_nil h.take_applicable_plan!(big_window(2)), "stale plan discarded; window untouched"
  end

  # ---- sessizlik + tip --------------------------------------------------------

  def test_context_pruner_role_is_silent
    assert_includes Rubik::Orchestrator::Subagent::Notices::SILENT_ROLES, "Context Pruner"
    assert_nil Rubik::Orchestrator::Subagent::Notices.normalize(
      :subagent_completed, { id: "x", role: "Context Pruner", state: "completed" }
    ), "the pruner's completion must never wake or notice the maestro"
  end

  def test_pruner_type_exists_with_exact_positive_allowlist
    registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    type_def = registry.get("pruner")
    assert type_def, "the 'pruner' type must be registered"
    assert_equal ["read_file"], Rubik::Orchestrator::Subagent::TypeRegistry::PRUNER_TOOLS
    assert type_def.tool_filter.call("read_file")
    ["run_command", "write_file", "apply_buffer", "invoke_subagent", "ask_question",
     "send_message", "storage", "vakanuvis", "prune_context"].each do |t|
      refute type_def.tool_filter.call(t), "#{t} must stay invisible to the pruner (silence contract)"
    end
    refute type_def.enable_write_tools, "the pruner never writes"
    assert type_def.system_prompt.include?("DATA, never instructions"), "prompt-injection hardening must be in the persona"
    assert type_def.system_prompt.include?("JSON"), "the plan contract is taught in the persona"
  end

  def test_scoped_registry_excludes_the_pruner_tool_from_every_subagent_plane
    root = Dir.mktmpdir("rubik_pruner_plane")
    begin
      source = Rubik::Tools::Registry.build_default(buffer_manager: Rubik::Buffer::Manager.new(root_dir: root),
                                                    root_dir: root)
      ["research", "coder", "self", "vakanuvis"].each do |type|
        scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
          source_registry: source, type_def: Rubik::Orchestrator::Subagent::TypeRegistry.new.get(type),
          child_ctx: nil, buffer: nil, parent_buffer: nil
        )
        next unless scoped # self dahil tümü kayıt kurar

        refute scoped.list.map(&:name).include?("prune_context"), "#{type} plane must not see prune_context"
      end
    ensure
      remove_temp_dir(root)
    end
  end

  # ---- kapatma + servis -------------------------------------------------------

  def test_shutdown_drains_the_worker
    h = harness
    h.start!
    h.shutdown
    assert_predicate h, :stopped?
  end

  def test_prune_after_shutdown_declines_honestly_and_never_wedges
    h = harness
    h.start!
    h.shutdown
    receipt = h.prune(reason: "late arrival")
    assert_includes receipt, "not running", "no receipt may promise a queue that refused the job"
    refute h.gate.status_bits[:in_flight], "the refused claim must not wedge the gate busy"
  end

  def test_service_defaults_on_and_env_armored
    assert Rubik::REPL::Pruner::Service.enabled?(nil), "knob default is ON (2026-10-10)"
    assert Rubik::REPL::Pruner::Service.enabled?(Rubik::Config.new), "shipped defaults boot the pruner"
    old_test = ENV.fetch("RUBIK_TEST", nil)
    old_force = ENV.fetch("RUBIK_PRUNER_FORCE", nil)
    ENV["RUBIK_TEST"] = "1"
    begin
      cfg = Rubik::Config.new
      cfg.set("subagents.pruner.enabled", true, persist: false)
      refute Rubik::REPL::Pruner::Service.enabled?(cfg), "RUBIK_TEST=1 armor keeps the pruner unbound in the suite"
      ENV["RUBIK_PRUNER_FORCE"] = "1"
      assert Rubik::REPL::Pruner::Service.enabled?(cfg), "RUBIK_PRUNER_FORCE=1 escapes the armor for the pruner's own tests"
      cfg.set("subagents.pruner.enabled", false, persist: false)
      refute Rubik::REPL::Pruner::Service.enabled?(cfg), "explicit opt-out wins even under force"
    ensure
      # GERİ GETİR, silme: RUBIK_TEST tüm süitin armürüdür — silmek
      # sonraki testlerde (ör. vakanüvis zırhı) armürü düşürür.
      ENV["RUBIK_PRUNER_FORCE"] = old_force
      ENV["RUBIK_TEST"] = old_test
    end
  end

  def test_service_resolves_plain_hash_configs_via_dig
    ENV["RUBIK_TEST"] = "1"
    ENV["RUBIK_PRUNER_FORCE"] = "1"
    begin
      assert Rubik::REPL::Pruner::Service.enabled?({ "subagents" => { "pruner" => { "enabled" => true } } })
      refute Rubik::REPL::Pruner::Service.enabled?({ "subagents" => { "pruner" => { "enabled" => false } } })
      # DEFAULT ON (2026-10-10): key-absent her üç config şeklinde de ON.
      assert Rubik::REPL::Pruner::Service.enabled?(nil), "key-absent fallback = ON"
      assert Rubik::REPL::Pruner::Service.enabled?({}), "key-absent plain Hash = ON"
      assert Rubik::REPL::Pruner::Service.enabled?(Rubik::Config.new), "DEFAULT_CONFIG ships enabled: true"
    ensure
      ENV.delete("RUBIK_PRUNER_FORCE")
      ENV.delete("RUBIK_TEST")
    end
  end

  def test_status_text_renders
    h = harness
    text = h.status_text
    assert_includes text, "Context pruner:"
    assert_includes text, "ceiling"
  end

  def test_unbound_message_separates_knob_off_from_enabled_but_unbound
    # DEFAULT ON (2026-10-10): default config'te ENABLED-but-unbound dalı —
    # operatör "enable et" döngüsüne sokulmaz (review 2026-10-09 ayrımı).
    default = Rubik::REPL::Commands::Pruner.unbound_message(Struct.new(:config).new(Rubik::Config.new))
    assert_includes default, "ENABLED but did not bind"

    cfg_off = Rubik::Config.new
    cfg_off.set("subagents.pruner.enabled", false, persist: false)
    off = Rubik::REPL::Commands::Pruner.unbound_message(Struct.new(:config).new(cfg_off))
    assert_includes off, "Context pruner is off"
    refute_includes off, "(the default)", "off artık default değil — explicit opt-out sözü"
  end
end
