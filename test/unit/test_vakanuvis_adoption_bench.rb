# frozen_string_literal: true

require_relative "../test_helper"

require "rubik/benchmark/vakanuvis_adoption"

# Vakanüvis araç-benimseme senaryosu (issue #338): deterministik düzlem —
# tohum depo, ReplayDriver profilleri GERÇEK araç düzlemini koşar ve
# metrik borusu üç ayrık davranış profilinde tam ayrışır. Bu testler
# tamamen çevrimdışıdır; canlı sürücü sözleşmesi LiveDriver#run_task
# imzası üzerinden dolaylı sabitlenir (tools.schemas/execute enjeksiyonu).
class TestVakanuvisAdoptionBench < Minitest::Test
  VA = Rubik::Benchmark::VakanuvisAdoption

  def run_profile(profile)
    root = Dir.mktmpdir("rubik_va_bench")
    begin
      store = VA.seed_store(root)
      harness = Rubik::Storage::Vakanuvis::Harness.new(store: store, config: VA::QuietConfig.new, session_slug: "test-#{profile}")
      tools = VA::ToolBench.new(store, harness)
      driver = VA::ReplayDriver.new(profile)
      runs = VA::TASKS.map { |task| driver.run_task(task, tools) }
      harness.shutdown
      [VA.metrics_for(driver.label, runs), store, runs]
    ensure
      FileUtils.remove_entry(root)
    end
  end

  def test_seed_store_is_deterministic_and_records_all_cards
    root_a = Dir.mktmpdir("rubik_va_bench")
    root_b = Dir.mktmpdir("rubik_va_bench")
    begin
      a = VA.seed_store(root_a)
      b = VA.seed_store(root_b)
      titles_a = a.list(type: "memory").map { |r| r["title"] }.sort
      titles_b = b.list(type: "memory").map { |r| r["title"] }.sort

      assert_equal VA::SEED_CARDS.size, titles_a.size, "every seed card lands as a memory row"
      assert_equal titles_a, titles_b, "seeding is deterministic — same cards, same store shape"
      assert titles_a.any? { |t| t.to_s.include?("geçidi") }, "the TR topic survives title minting"
      assert titles_a.any? { |t| t.to_s.include?("Sandbox") }, "the EN topic survives title minting"
    ensure
      FileUtils.remove_entry(root_a)
      FileUtils.remove_entry(root_b)
    end
  end

  def test_adopter_profile_uses_recall_then_vakanuvis_record
    metrics, _store, runs = run_profile("adopter")

    assert metrics.recall_called, "adopter calls recall"
    assert_equal 1, metrics.first_recall_turn, "recall happens on the first turn"
    assert_equal 1, metrics.recall_calls
    assert_equal 4.0, metrics.avg_query_terms, "gateway retry backoff 429 — four terms"
    refute metrics.keywords_line_used
    assert_equal 0, metrics.recall_empty_rate, "the seeded card answers the exact keyword-AND query"
    assert metrics.record_called, "durable conclusion goes through vakanuvis record"
    assert_equal 0, metrics.wrong_path_puts
    assert metrics.answer_used_recall, "the answer quotes the card's distinctive backoff values"
    refute metrics.hit_turn_cap
    assert runs.all? { |r| r[:calls].all? { |_n, _a, res| !res.to_s.empty? } }, "real tools produce real results"
  end

  def test_wrong_path_profile_never_recalls_and_writes_via_storage_put
    metrics, _store, _runs = run_profile("wrong-path")

    refute metrics.recall_called
    assert_nil metrics.first_recall_turn
    assert_nil metrics.avg_query_terms, "no recall ⇒ no query-term average"
    refute metrics.record_called
    assert_equal 1, metrics.wrong_path_puts, "direct storage put on memory is the wrong path"
    refute metrics.answer_used_recall, "an invented answer cannot carry the card's values"
  end

  def test_struggler_profile_shows_empty_first_recall_then_keyword_retry
    metrics, _store, _runs = run_profile("struggler")

    assert metrics.recall_called
    assert_equal 2, metrics.recall_calls, "over-specific TR query, then the Keywords-line retry"
    assert_equal 50, metrics.recall_empty_rate, "the fallback-only first query counts as empty (issue wording)"
    assert metrics.record_called
    assert_equal 0, metrics.wrong_path_puts
    assert metrics.answer_used_recall, "the eventual answer does quote the card"
  end

  def test_tool_bench_executes_real_tools_and_rejects_unknown_names
    root = Dir.mktmpdir("rubik_va_bench")
    begin
      store = VA.seed_store(root)
      harness = Rubik::Storage::Vakanuvis::Harness.new(store: store, config: VA::QuietConfig.new, session_slug: "tb")
      tools = VA::ToolBench.new(store, harness)

      recall = tools.execute("vakanuvis", { "action" => "recall", "query" => "gateway retry backoff" })
      assert_includes recall.to_s, "Recalled", "the real recall plane answers from the seeded store"
      assert_includes tools.execute("nope", {}).to_s, "Unknown tool"

      schemas = tools.schemas
      names = schemas.map { |s| s[:name] || s["name"] }
      assert_includes names, "vakanuvis"
      assert_includes names, "storage", "the wrong path stays AVAILABLE — otherwise wrong-path rate is a fake zero"
    ensure
      FileUtils.remove_entry(root)
    end
  end

  def test_metric_results_renders_per_model_rows
    rows = VA.run(VA::REPLAY_PROFILES.map { |p| VA::ReplayDriver.new(p) }, io: StringIO.new)
    out = StringIO.new
    results = VA.metric_results(rows, io: out)

    assert_equal 3, results.size
    assert(results.all? { |r| r.passed && r.name.start_with?("Vakanüvis Tool Adoption — scripted/") })
    table = out.string
    assert_includes table, "| model | recall | first@ |"
    assert_includes table, "| scripted/adopter | yes | 1 |"
    assert_includes table, "| scripted/wrong-path | NO | - |"
    assert_includes table, "| scripted/struggler | yes | 1 | 2 | 8.0 | no | 50% |"
  end

  def test_live_driver_contract_executes_against_a_stub_provider
    # LiveDriver'ın complete → tool_calls → tool sonucu → final metin
    # döngüsü, sahte provider ile: davranış sabitlenir, ağ gerekmez.
    root = Dir.mktmpdir("rubik_va_bench")
    begin
      store = VA.seed_store(root)
      harness = Rubik::Storage::Vakanuvis::Harness.new(store: store, config: VA::QuietConfig.new, session_slug: "live-stub")
      tools = VA::ToolBench.new(store, harness)

      turns = [
        lambda do |_history|
          Rubik::LLM::Response.new(
            text: "",
            tool_calls: [{ "id" => "call-1", "tool" => "vakanuvis",
                           "args" => { "action" => "recall", "query" => "gateway retry backoff 429" } }]
          )
        end,
        ->(_history) { Rubik::LLM::Response.new(text: "Üstel geri çekilme 2s, 4s, 8s — en fazla 5 deneme.") }
      ]
      provider = Struct.new(:name, :model).new("stub", "stub-1")
      provider.define_singleton_method(:complete) { |history, _opts| turns.shift.call(history) }

      run = VA::LiveDriver.new(provider).run_task(VA::TASKS.first, tools)

      assert_equal 2, run[:turns]
      assert_equal 1, run[:first_recall_turn]
      assert run[:calls].first[2].to_s.start_with?("Recalled "), "the stub loop feeds REAL tool results back"
      assert VA.send(:answer_uses_recall?, run[:answer])
      refute run[:hit_cap]
    ensure
      FileUtils.remove_entry(root)
    end
  end
end
