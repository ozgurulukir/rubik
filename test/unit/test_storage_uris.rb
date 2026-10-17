# frozen_string_literal: true

require_relative "../test_helper"

# rubik://storage okuma düzlemi: read_file URI rotaları (UriReader), absorb
# yerleşimi (Layout), transcript mint/resolve ve otomatik indeksleme.
class TestStorageUris < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage_uris")
    @workdir = Dir.mktmpdir("rubik_storage_ws")
    @store = Rubik::Storage::Store.new(root: @root, project: "uriproj")
    @ctx = Rubik::Runtime::Context.new
    @ctx.provide(Rubik::Coeffects::STORAGE_STORE, @store)
    @buffer = Rubik::Buffer::Manager.new(root_dir: @workdir)
    @reader = Rubik::Tools::ReadFileTool.new(@buffer, runtime_context: @ctx)
  end

  def teardown
    @ctx&.dispose unless @ctx&.disposed?
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@workdir) if @workdir && Dir.exist?(@workdir)
  end

  def read(path)
    @reader.execute({ "path" => path })
  end

  def test_index_listing_entity_refs_and_default_project_forms
    record = @store.put(type: "goal", title: "G1", body: "the body", ref: "active-goal")
    assert_includes read("rubik://storage/index"), "Rubik storage central index"
    assert_includes read("rubik://storage/uriproj"), "Storage project: uriproj"
    assert_includes read("rubik://storage/uriproj/goal"), "| 1 | `#{record['id']}`"
    assert_includes read("rubik://storage/uriproj/goal"), "active-goal → #{record['id']}",
                    "listings surface the aliases pointing into the type"
    assert_includes read("rubik://storage/goal/1"), "the body", "default-project form"
    assert_includes read("rubik://storage/goal/1.json"), record["hash"], "raw json form"
    assert_includes read("rubik://storage/uriproj/refs/active-goal"), "# #{record['id']}"
  end

  def test_cross_project_entity_reads_use_target_store_view
    other = Rubik::Storage::Store.new(root: @root, project: "elsewhere")
    other.put(type: "plan", title: "theirs")
    assert_includes read("rubik://storage/elsewhere/plan/1"), "theirs"
    assert_includes read("rubik://storage/elsewhere"), "plan: 1"
  end

  def test_error_paths_are_honest
    assert_includes read("rubik://storage/goal/99"), "not found"
    assert_includes read("rubik://storage/uriproj/bogus/1"), "Unknown entity type"
    assert_includes read("rubik://storage/refs/x"), "needs a project"
    bare = Rubik::Tools::ReadFileTool.new(@buffer)
    assert_includes bare.execute({ "path" => "rubik://storage/index" }), "not available"
  end

  def test_unknown_type_suggests_the_near_miss
    # Olay #3 (2026-10-04): 'transcripts' çoğulu yalnız hata listesiyle
    # değil, doğrudan öneriyle karşılanmalı.
    error = read("rubik://storage/uriproj/transcripts/1")
    assert_includes error, "Unknown entity type"
    assert_includes error, "Did you mean 'transcript'?"
  end

  def test_not_found_suggests_related_alias_routes
    # Olay #4: alias keşfi liste çıktısındaki Refs satırına mahkum değil —
    # isabet almayan okumalar rotayı doğrudan önerir.
    transcript = @store.put(type: "transcript", title: "t1", ref: "subagent-subagent-1-12456-8611")
    @store.put(type: "note", title: "n1", ref: "final-release-notes")
    @store.put(type: "note", title: "n2", ref: "unrelated")

    # Olayın birebir imzası: doğal form artık transcript tipinde çözümlenir
    # (legacy çift önek fallback'i; store seviyesindeki eş testi var).
    assert_includes read("rubik://storage/uriproj/transcript/subagent-1-12456-8611"),
                    transcript["id"]

    # Yanlış tip: çözümleme düşer, ama alias adayı rota olarak önerilir.
    wrong_type = read("rubik://storage/uriproj/note/subagent-1-12456-8611")
    assert_includes wrong_type, "not found"
    assert_includes wrong_type, "rubik://storage/uriproj/refs/subagent-subagent-1-12456-8611"

    # Sonek biçimli eşleşme (alias, selektörü sonunda taşır).
    suffix = read("rubik://storage/uriproj/note/release-notes")
    assert_includes suffix, "rubik://storage/uriproj/refs/final-release-notes"

    refute_includes read("rubik://storage/uriproj/note/unrelated-thing"), "Related aliases",
                    "non-matching aliases are not advertised"
    refute_includes read("rubik://storage/uriproj/note/rel"), "Related aliases",
                    "short selectors do not flood with suffix guesses"
  end

  def test_research_archetype_reads_storage_but_cannot_write
    research = Rubik::Orchestrator::Subagent::TypeRegistry::READ_ONLY_TOOLS
    coder = Rubik::Orchestrator::Subagent::TypeRegistry::CODER_TOOLS
    assert_includes research, "read_file", "read plane rides read_file URI routes"
    refute_includes research, "storage"
    assert_includes coder, "storage", "write plane belongs to the coder archetype"
    registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    read_only_custom = registry.define_custom(name: "scribe", description: "d", system_prompt: "s", context: @ctx)
    refute read_only_custom.tool_filter.call("storage"), "custom write-disabled archetypes must not write storage"
    assert read_only_custom.tool_filter.call("read_file")
  end

  # Prompt yüzeyleri (2026-09-30 denetimi): modelin depoyu KEŞFETMESİ için
  # read_file şeması rubik:// şemalarını, archetype promptları da kendi
  # erişim düzlemlerini söylemek zorunda.
  def test_read_file_schema_documents_virtual_rubik_uris
    schema = Rubik::Tools::ReadFileTool.new(@buffer).params_schema
    path_doc = schema[:properties][:path][:description]
    assert_includes path_doc, "rubik://storage/<project>/<type>/<id>", "storage read plane must be discoverable in the schema"
    assert_includes path_doc, "rubik://goal/state"
    assert_includes path_doc, "rubik://subagent/<storage-id>/transcript",
                    "the transcript route must name the UNIQUE storage id (issue #129)"
    assert_includes path_doc, "display id", "the schema must warn that a display id is not an address"
  end

  def test_archetype_prompts_advertise_their_storage_planes
    registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    research_prompt = registry.get("research").system_prompt
    coder_prompt = registry.get("coder").system_prompt
    assert_includes research_prompt, "rubik://storage", "research prompt must advertise read-only URI access"
    assert_includes research_prompt, "Codebase Research Subagent", "existing persona contract preserved"
    assert_includes coder_prompt, "'storage' tool", "coder prompt must advertise the write plane"
    assert_includes coder_prompt, "`note`, `plan`, `review`",
                    "coder prompt must scope routine storage puts to work artifacts"
    assert_includes coder_prompt, "surface durable lessons in your report so the maestro can record them via `vakanuvis`",
                    "coder prompt must explain how durable memory is recorded when vakanuvis is root-only"
    refute_includes coder_prompt, "Persist work notes, findings, and memory to the central store with the 'storage' tool",
                    "coder prompt must not instruct routine raw memory puts"
    assert_includes coder_prompt, "Coding Subagent"
  end
end

# Absorb yerleşimi: absorb_artifacts? DI doktrini (nil/eksik anahtar → legacy),
# sessions_dir_for, transcript mint/resolve ve TranscriptIndexer.
class TestStorageAbsorb < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage_absorb")
    @workdir = Dir.mktmpdir("rubik_storage_absorb_ws")
    @orig_home = ENV.fetch("HOME", nil)
    @store = Rubik::Storage::Store.new(root: @root, project: "absorbproj")
    @absorb_config = { "storage" => { "absorb_artifacts" => true } }
  end

  def teardown
    [@root, @workdir].each { |d| FileUtils.remove_entry(d) if d && Dir.exist?(d) }
  end

  def test_absorb_flag_requires_explicit_config
    layout = Rubik::Storage::Layout
    refute layout.absorb_artifacts?(nil), "bare constructions must stay legacy (DI doctrine)"
    refute layout.absorb_artifacts?({})
    assert layout.absorb_artifacts?(@absorb_config)
    refute layout.absorb_artifacts?({ "storage" => { "absorb_artifacts" => false } })
  end

  def test_sessions_dir_for_switches_between_absorbed_and_legacy
    layout = Rubik::Storage::Layout
    assert_equal File.join(@root, "absorbproj", "sessions"),
                 layout.sessions_dir_for(@workdir, @absorb_config.merge("storage" => { "absorb_artifacts" => true, "root" => @root, "project" => "absorbproj" }))
    legacy = layout.sessions_dir_for(@workdir, nil)
    assert_equal File.join(File.expand_path(@workdir), ".rubik", "sessions"), legacy
  end

  def test_transcript_mint_and_resolve_prefer_absorbed_root
    formatter = Rubik::Orchestrator::Subagent::TranscriptFormatter
    legacy = formatter.transcript_path_for(@workdir, "sid-1")
    assert_equal legacy, formatter.mint_path(@workdir, "sid-1"), "no store → legacy root"
    assert_equal legacy, formatter.resolve(@workdir, "sid-1"), "resolve falls back to legacy when no store"

    absorbed = formatter.mint_path(@workdir, "sid-1", storage: @store)
    assert_equal File.join(@root, "absorbproj", "subagents", "sid-1", "transcript.jsonl"), absorbed

    assert_equal legacy, formatter.resolve(@workdir, "sid-1", storage: @store), "missing absorbed file → legacy"
    FileUtils.mkdir_p(File.dirname(absorbed))
    File.write(absorbed, "[]")
    assert_equal absorbed, formatter.resolve(@workdir, "sid-1", storage: @store), "absorbed wins when present"
  end

  def test_instance_mints_absorbed_transcript_when_storage_given
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-1", parent_id: "agent-0", role: "r", type_name: "research",
      prompt: "p", context: nil, tool_registry: nil, root_dir: @workdir,
      transcript_storage: @store
    )
    assert inst.transcript_uri.start_with?(File.join(@root, "absorbproj", "subagents"))
    legacy = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-2", parent_id: "agent-0", role: "r", type_name: "research",
      prompt: "p", context: nil, tool_registry: nil, root_dir: @workdir
    )
    assert legacy.transcript_uri.start_with?(File.join(File.expand_path(@workdir), ".rubik"))
  end

  def test_transcript_indexer_upserts_searchable_entity
    inst = Object.new
    def inst.type_name = "coder"
    def inst.role = "impl"
    def inst.id = "subagent-7"
    def inst.state = :completed
    def inst.storage_id = "sid-7"
    def inst.transcript_uri = "/nonexistent/transcript.jsonl"
    Rubik::Storage::TranscriptIndexer.index(@store, inst)
    record = @store.get(type: "transcript", id: "subagent-sid-7")
    refute_nil record, "ref subagent-<storage-id> must resolve"
    assert_includes record["title"], "[coder] impl (subagent-7) — completed"
    assert_equal "sid-7", record["links"]["subagent_id"]
    assert_includes record["body"], "transcript file unavailable"
    # Issue #97 finding 5: the canonical rubik:// route rides in the entity
    # itself so recall consumers land on show_file in one hop, instead of
    # first hitting a read_file denial on the raw path.
    assert_equal "rubik://subagent/sid-7/transcript", record["links"]["canonical"]

    assert_nil Rubik::Storage::TranscriptIndexer.index(nil, inst), "nil store is a no-op"
    broken = Object.new
    def broken.type_name = raise(StandardError, "boom")
    assert_nil Rubik::Storage::TranscriptIndexer.index(@store, broken), "indexing failure must never raise"
  end

  def test_transcript_indexer_is_a_true_upsert_across_recompletions
    inst = Object.new
    def inst.type_name = "coder"
    def inst.role = "impl"
    def inst.id = "subagent-9"
    def inst.state = :completed
    def inst.storage_id = "sid-9"
    def inst.transcript_uri = "/nonexistent/transcript.jsonl"
    Rubik::Storage::TranscriptIndexer.index(@store, inst)
    # Resume sonrası ikinci tamamlanma: aynı ref → aynı satır, version artar.
    Rubik::Storage::TranscriptIndexer.index(@store, inst)
    records = @store.list(type: "transcript")
    assert_equal 1, records.length, "re-completion must not duplicate the transcript entity"
    assert_equal 2, @store.get(type: "transcript", id: "subagent-sid-9")["version"]
  end

  def test_transcript_index_body_is_task_and_result_centric
    path = File.join(@workdir, "body_probe", "transcript.jsonl")
    rows = [
      { role: "system", content: "ASSEMBLED-BOILERPLATE-never-indexed" },
      { role: "user", content: "Find the login flow and report VERDICT" },
      { role: "assistant", content: nil, tool_calls: nil },
      { role: "tool", tool_call_id: "t", tool_name: "read_file", status: :ok, duration_ms: 1.0, content: "noise" }
    ]
    Rubik::Orchestrator::Subagent::TranscriptFormatter.save!(path, rows, Monitor.new, prompt_reconstructible: true)

    inst = Object.new
    inst.define_singleton_method(:type_name) { "research" }
    inst.define_singleton_method(:role) { "scout" }
    inst.define_singleton_method(:id) { "subagent-11" }
    inst.define_singleton_method(:state) { :completed }
    inst.define_singleton_method(:storage_id) { "sid-11" }
    inst.define_singleton_method(:result) { "VERDICT: green — token ghp_#{'b' * 36} leaked into the report" }
    inst.define_singleton_method(:transcript_uri) { path }
    Rubik::Storage::TranscriptIndexer.index(@store, inst)

    record = @store.get(type: "transcript", id: "subagent-sid-11")
    refute_nil record, "ref subagent-<storage-id> must resolve"
    assert_includes record["body"], "[task] Find the login flow and report VERDICT"
    assert_includes record["body"], "[result] VERDICT: green"
    refute_includes record["body"], "ghp_#{'b' * 36}",
                    "the store body is durable+searchable — raw-memory text is redacted first"
    refute_includes record["body"], "ASSEMBLED-BOILERPLATE-never-indexed",
                    "system-prompt text never enters the search corpus"
    refute_includes record["body"], "noise", "transcript chatter stays out of the indexed body"
  end

  def test_failed_transcript_index_still_builds_body_with_state_line
    inst = Object.new
    def inst.type_name = "coder"
    def inst.role = "impl"
    def inst.id = "subagent-12"
    def inst.state = :failed
    def inst.storage_id = "sid-12"
    def inst.prompt = "audit the exports"
    def inst.result = nil
    def inst.transcript_uri = "/nonexistent/transcript.jsonl"
    Rubik::Storage::TranscriptIndexer.index(@store, inst)

    body = @store.get(type: "transcript", id: "subagent-sid-12")["body"]
    assert_includes body, "[task] audit the exports (transcript file unavailable)"
    assert_includes body, "[state] failed — no result recorded"
  end

  def test_long_result_is_clipped_to_the_part_limit
    inst = Object.new
    def inst.type_name = "research"
    def inst.role = "scout"
    def inst.id = "subagent-13"
    def inst.state = :completed
    def inst.storage_id = "sid-13"
    def inst.prompt = "p"
    def inst.result = "R" * 5000
    def inst.transcript_uri = "/nonexistent/transcript.jsonl"
    Rubik::Storage::TranscriptIndexer.index(@store, inst)

    body = @store.get(type: "transcript", id: "subagent-sid-13")["body"]
    assert_includes body, "... [truncated 3800 chars]"
    assert_operator body.length, :<, 2000, "the composed body stays near the per-part caps"
  end

  # Review bulgusu 1: supervisor Composition'da kurulur, STORAGE_STORE ise
  # Phase 4'te (SONRA) provide edilir — ctor snapshot'ı üretilimde ölü kalır.
  # Çözüm kullanım anında (lazy) resolution; bu test sıralamayı sabitler.
  def test_supervisor_resolves_storage_lazily_after_phase4_provide
    ctx = Rubik::Runtime::Context.new
    config = { "storage" => { "absorb_artifacts" => true } }
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: ctx, config: config, root_dir: @workdir)
    assert_nil supervisor.send(:storage_store), "before Phase 4 there is no store yet"

    store = Rubik::Storage::Store.new(root: @root, project: "late")
    ctx.provide(Rubik::Coeffects::STORAGE_STORE, store)
    assert_equal store, supervisor.send(:storage_store)
    assert_equal store, supervisor.send(:absorb_storage), "absorb config on → store flows to transcript mint"

    no_absorb = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: ctx, config: { "storage" => { "absorb_artifacts" => false } }, root_dir: @workdir
    )
    assert_nil no_absorb.send(:absorb_storage), "absorb off → transcripts mint to the legacy root"
  ensure
    supervisor&.shutdown_all
    no_absorb&.shutdown_all
  end

  def test_manager_scan_honors_storage_root_override
    # Review bulgusu 2: recorder config-aware yazar; okuma da öyle olmalı.
    config = { "storage" => { "root" => @root, "project" => "overrideproj", "absorb_artifacts" => true } }
    assert_equal File.join(@root, "overrideproj", "sessions"),
                 Rubik::Session::Manager.absorbed_sessions_dir(@workdir, config)
    listed = Rubik::Session::Manager.list_sessions(@workdir, ENV.fetch("HOME", nil), config: config)
    assert_equal [], listed, "empty overridden root must list cleanly (no default-root leakage)"
  end

  def test_manager_lists_absorbed_sessions_alongside_legacy
    # Varsayılan storage kökü HOME'dan çözülür: izole bir HOME ile absorbed
    # oturum dizinini oluşturup list_sessions'ın ikisini de görmesini doğrula.
    stub_home = Dir.mktmpdir("rubik_storage_home")
    ENV["HOME"] = stub_home
    slug = Rubik::Storage::Layout.project_slug(@workdir)
    absorbed_dir = Rubik::Storage::Layout.absorbed_sessions_dir(Rubik::Storage::Layout.storage_root, slug)
    FileUtils.mkdir_p(absorbed_dir)
    File.write(File.join(absorbed_dir, "session_absorbed.jsonl"),
               "#{JSON.generate({ 'type' => 'user_turn', 'payload' => { 'content' => 'hi' } })}\n")
    legacy_dir = Rubik::Session::Manager.project_sessions_dir(@workdir)
    FileUtils.mkdir_p(legacy_dir)
    File.write(File.join(legacy_dir, "session_legacy.jsonl"),
               "#{JSON.generate({ 'type' => 'user_turn', 'payload' => { 'content' => 'old' } })}\n")

    listed = Rubik::Session::Manager.list_sessions(@workdir)
    names = listed.map { |s| File.basename(s[:path]) }
    assert_includes names, "session_absorbed.jsonl"
    assert_includes names, "session_legacy.jsonl"

    latest = Rubik::Session::Manager.find_latest_session(@workdir)
    # Absorbed daha yeni olduğundan (sonra yazıldı) öncelik sırası absorbed.
    assert_equal "session_absorbed.jsonl", File.basename(latest)
  ensure
    FileUtils.remove_entry(stub_home) if stub_home && Dir.exist?(stub_home)
    ENV["HOME"] = @orig_home
  end
end

# storage_route_hints: fiziksel storage yolu -> kanonik rubik:// rotaları
# (sandbox kapısı diagnostic'ının olay #1 iyileştirmesi).
class TestStorageRouteHints < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage_hints")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def config
    { "storage" => { "root" => @root } }
  end

  def hints(path)
    Rubik::Storage::Layout.storage_route_hints(path, config)
  end

  def test_subagent_transcript_maps_to_the_canonical_route
    FileUtils.mkdir_p(File.join(@root, "js-tangram", "subagents", "subagent-1-8611"))
    raw = File.join(@root, "js-tangram", "subagents", "subagent-1-8611", "transcript.jsonl")
    assert_equal ["rubik://subagent/subagent-1-8611/transcript",
                  "rubik://storage/js-tangram/transcript"], hints(raw)
  end

  def test_store_files_map_to_listings_and_meta_to_project
    FileUtils.mkdir_p(File.join(@root, "js-tangram", "store"))
    assert_equal ["rubik://storage/js-tangram/transcript"],
                 hints(File.join(@root, "js-tangram", "store", "transcript.jsonl"))
    assert_equal ["rubik://storage/js-tangram"],
                 hints(File.join(@root, "js-tangram", "store", "meta.json"))
    File.write(File.join(@root, "index.json"), "{}")
    assert_equal ["rubik://storage/index"], hints(File.join(@root, "index.json"))
  end

  def test_unknown_shapes_fall_back_to_the_project_route
    FileUtils.mkdir_p(File.join(@root, "js-tangram", "sessions"))
    assert_equal ["rubik://storage/js-tangram"], hints(File.join(@root, "js-tangram", "sessions", "s.jsonl"))
    # Depo dizinleri slug basılıdır (Store slugify yazar); selektör varyantı
    # slug'a normalize edilir ve varlık o adreste aranır.
    FileUtils.mkdir_p(File.join(@root, "other-proj"))
    assert_equal ["rubik://storage/other-proj"], hints(File.join(@root, "Other Proj!", "random.txt"))
  end

  def test_nonexistent_projects_and_missing_index_hint_nothing
    # Olay takibi M2: ipucu yalnız gerçekten depo verisi olan hedefe
    # verilir — custom storage.root kurulumunda DEFAULT kök altındaki
    # bayat yollar var olmayan rotalara yönlendirilemez.
    assert_equal [], hints(File.join(@root, "ghost-proj", "subagents", "s", "transcript.jsonl"))
    assert_equal [], hints(File.join(@root, "ghost-proj", "store", "goal.jsonl"))
    assert_equal [], hints(File.join(@root, "index.json"))
  end

  def test_paths_outside_the_root_hint_nothing
    assert_equal [], hints(File.join(@root, "..", "elsewhere", "x.jsonl"))
    assert_equal [], hints("C:/definitely/not/storage/x.jsonl")
    assert_equal [], hints(nil)
    # L1: total-function sözleşmesi — normalize edilemeyen yol asla
    # diagnostic'ı devirmemeli (File.expand_path NUL byte'ta patlar).
    assert_equal [], hints("bad\0path")
  end
end
