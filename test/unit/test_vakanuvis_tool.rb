# frozen_string_literal: true

require_relative "../test_helper"

# vakanuvis aracı (talep düzlemi — plan 2026-10-04 §4.5/K7): recall
# determinizmi, record upsert/replay, forget izi, digest makbuz
# determinizmi, aracın yalnız-maestro görünürlüğü (ScopedRegistry
# ROOT_ONLY + REQUIRES gizleme) ve dürüst hata yolları.
class TestVakanuvisTool < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_vakanuvis_tool")
    @store = Rubik::Storage::Store.new(root: @root, project: "toolproj")
    @harness = Rubik::Storage::Vakanuvis::Harness.new(store: @store, session_slug: "tool-suite")
  end

  def teardown
    @harness.shutdown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def tool(harness = @harness, runtime_context: nil)
    Rubik::Tools::VakanuvisTool.new(harness, runtime_context: runtime_context)
  end

  def test_declaration_is_maestro_plane_only
    d = Rubik::Tools::VakanuvisTool::DECLARATION
    assert_equal "vakanuvis", d.name
    assert_empty d.archetypes, "empty archetypes keep the tool out of research/coder planes"
    refute d.write_grant?
    refute d.maestro_blocked?, "chronicler desk is direct at root (storage precedent)"
    assert_equal :write, d.risk
    assert_equal [Rubik::Coeffects::VAKANUIS], Rubik::Tools::VakanuvisTool::REQUIRES
  end

  def test_recall_is_deterministic_digest_with_source_links
    @harness.record(topic: "release gate", body: "run unit suite before tagging the release")
    @store.put(type: "wiki", title: "Release wiki", body: "release checklist compiled", ref: "wiki.release-gate")

    first = tool.execute({ "action" => "recall", "query" => "release" })
    second = tool.execute({ "action" => "recall", "query" => "release" })
    assert_equal first, second, "same store + same query must return the byte-identical digest (LLM-free)"
    assert_includes first, "release gate"
    assert_includes first, "rubik://storage/toolproj/memory/"
    assert_includes first, "rubik://storage/toolproj/wiki/"
  end

  def test_recall_respects_scope_types_and_reports_empty_honestly
    @harness.record(topic: "scope test", body: "memory only card")
    scoped = tool.execute({ "action" => "recall", "query" => "scope", "types" => ["wiki"] })
    assert_includes scoped, "No chronicled knowledge matches"
    refute_includes scoped, "mem."
  end

  def test_empty_recall_suggests_term_and_language_retry_before_recording
    out = tool.execute({ "action" => "recall", "query" => "missing entirely" })
    assert_includes out, "keyword-AND", "the empty hit explains the matching semantics"
    assert_includes out, "other-language", "the language-mismatch miss (TR query vs EN page) is called out"
    assert_match(/record.*digest|record.*or queue/m, out)
  end

  def test_empty_and_recall_offers_labeled_fallback_hits
    @harness.record(topic: "handshake lesson", body: "lock ordering discipline under contention")
    out = tool.execute({ "action" => "recall", "query" => "handshake unrelatedterminology" })
    assert_includes out, "No exact keyword-AND match", "the miss is still called a miss"
    assert_includes out, "(fallback)", "partial matches are honestly labeled"
    assert_includes out, "handshake lesson"
  end

  def test_recall_fallback_counts_matching_transcripts_as_a_scope_hint
    @store.put(type: "transcript", title: "session log", body: "handshake retry storm observed")
    out = tool.execute({ "action" => "recall", "query" => "handshake retry" })
    assert_match(/1 transcript entr(y|ies) mention these terms/, out, "the scope hint counts AND-matching transcripts")
    assert_includes out, "queue a digest"
    refute_includes out, "(fallback)", "no phantom fallback list when the OR pass finds nothing"
    refute_includes out, "Read a full record", "no read_file instruction when there is no URI above it"
  end

  def test_declaration_teaches_the_bilingual_keywords_line
    schema = Rubik::Tools::VakanuvisTool::DECLARATION.params_schema
    body_desc = schema[:properties][:body][:description]
    query_desc = schema[:properties][:query][:description]
    assert_includes body_desc, "Keywords:", "record bodies must end with a bilingual keyword line"
    assert_includes query_desc, "other-language", "recall's empty-result guidance lives in the schema too"
  end

  def test_record_upserts_by_topic_and_replay_freezes_version
    first = tool.execute({ "action" => "record", "topic" => "deploy steps", "body" => "1. gates 2. tag 3. push" })
    assert_includes first, "mem.deploy-steps"
    assert_includes first, "version 1"
    row = @store.get(type: "memory", id: "mem.deploy-steps")
    assert_equal 1, row["version"]

    replay = tool.execute({ "action" => "record", "topic" => "deploy steps", "body" => "1. gates 2. tag 3. push" })
    assert_includes replay, "unchanged (version 1 kept)", "identical content must skip the put (hash comparison)"
    assert_equal 1, @store.get(type: "memory", id: "mem.deploy-steps")["version"]

    updated = tool.execute({ "action" => "record", "topic" => "deploy steps", "body" => "1. gates 2. tag 3. push 4. announce" })
    assert_includes updated, "version 2"
    assert_equal 2, @store.get(type: "memory", id: "mem.deploy-steps")["version"], "changed content upserts the same row"
  end

  def test_record_accepts_tags_and_reports_auto_extracted_keywords
    out = tool.execute({ "action" => "record", "topic" => "tagged card", "body" => "rotate keys quarterly",
                         "tags" => ["infra"] })
    assert_includes out, "Keywords auto-extracted", "the repair is visible, not silent"
    row = @store.get(type: "memory", id: "mem.tagged-card")
    assert_equal ["infra", "memory", "vakanuvis"], row["tags"], "user tags merge with the vocabulary"
  end

  def test_record_splits_comma_separated_string_tags_and_rejects_scalars
    tool.execute({ "action" => "record", "topic" => "string tags", "body" => "rotate keys quarterly",
                   "tags" => "infra, db" })
    row = @store.get(type: "memory", id: "mem.string-tags")
    assert_equal ["db", "infra", "memory", "vakanuvis"], row["tags"], "a comma string splits like the storage tool"

    scalar = tool.execute({ "action" => "record", "topic" => "scalar tags", "body" => "rotate keys quarterly",
                            "tags" => false })
    assert_includes scalar, "vakanuvis record:"
    assert_includes scalar, "array of strings"
    assert_nil @store.get(type: "memory", id: "mem.scalar-tags"), "the rejected record opens no row"
  end

  def test_record_warns_when_no_keywords_can_be_extracted
    out = tool.execute({ "action" => "record", "topic" => "ve bu", "body" => "ve bu da" })
    assert_includes out, "no Keywords: line and none could be extracted",
                    "the unrecallable card is flagged, not silently stored"
  end

  def test_forget_reports_trace_and_missing_ref_honestly
    tool.execute({ "action" => "record", "topic" => "temp fact", "body" => "scratch" })
    out = tool.execute({ "action" => "forget", "ref" => "mem.temp-fact" })
    assert_includes out, "superseded (status + trace link kept)"

    missing = tool.execute({ "action" => "forget", "ref" => "mem.nothing" })
    assert_includes missing, "Nothing to forget"
  end

  def test_forget_renders_the_note_uri_for_retired_notes
    @store.put(type: "note", title: "scout report", body: "findings", ref: "annal.scout-1")
    out = tool.execute({ "action" => "forget", "ref" => "annal.scout-1" })
    assert_includes out, "superseded"
    assert_includes out, "rubik://storage/toolproj/note/"
  end

  def test_digest_receipt_is_deterministic_and_names_the_target_ref
    first = tool.execute({ "action" => "digest", "query" => "release pipeline" })
    second = tool.execute({ "action" => "digest", "query" => "release pipeline" })
    assert_includes first, "Digest queued (async)", "the maestro must know the compile happens later, async"
    assert_includes first, "wiki.release-pipeline", "receipt names the deterministic target ref"
    assert_includes first, "No distiller run started yet",
                    "without a distiller (this harness has no supervisor) the receipt says so honestly"
    # v2 §4-V5: aynı hedef kuyrukta ya da uçuştaysa makbuz 'already queued' varyantına düşer.
    assert_includes second, "Digest already queued for 'wiki.release-pipeline'",
                    "a repeat digest for an in-flight target dedupes to the already-queued receipt"
  end

  def test_error_paths_are_empathetic_not_silent
    out = tool.execute({ "action" => "recall", "query" => "   " })
    assert_includes out, "vakanuvis recall", "ArgumentError surfaces with the action named"

    unknown = tool.execute({ "action" => "purge", "ref" => "mem.x" })
    assert_includes unknown, "Unknown vakanuvis action 'purge'"
    assert_includes unknown, "topics", "the valid-action list names the new actions"
    assert_includes unknown, "digest_status"
  end

  def test_digest_status_is_deterministic_and_names_targets
    first = tool.execute({ "action" => "digest_status" })
    assert_includes first, "nothing queued, nothing in flight"

    tool.execute({ "action" => "digest", "query" => "status pipeline" })
    second = tool.execute({ "action" => "digest_status" })
    assert_includes second, "1 queued (wiki.status-pipeline)",
                    "without a supervisor the digest stays queued — and is now visible"
    assert_equal second, tool.execute({ "action" => "digest_status" }), "the status string is deterministic"
  end

  def test_topics_lists_active_memory_cards_with_uris_in_ref_order
    @harness.record(topic: "zeta topic", body: "later card")
    @harness.record(topic: "alpha topic", body: "earlier card")
    out = tool.execute({ "action" => "topics" })
    assert_includes out, "Recorded topics (2):"
    assert_includes out, "mem.alpha-topic"
    assert_includes out, "rubik://storage/toolproj/memory/"
  end

  def test_topics_ignores_superseded_and_unbound_memory_rows
    @harness.record(topic: "keeper", body: "stays queryable")
    @store.put(type: "memory", title: "rogue", body: "unbound raw put")
    tool.execute({ "action" => "forget", "ref" => "mem.keeper" })
    out = tool.execute({ "action" => "topics" })
    refute_includes out, "mem.keeper", "superseded cards leave the orientation surface"
    refute_includes out, "rogue", "unbound raw rows never masquerade as topics"
  end

  def test_unwired_harness_reports_disability_not_crash
    out = tool(nil).execute({ "action" => "recall", "query" => "x" })
    assert_includes out, "not available"
    assert_includes out, "subagents.vakanuvis.enabled"
  end

  # ---- görünürlük: subagent düzlemleri kronikçiden habersizdir (K7) ------

  def test_scoped_registry_never_copies_the_chronicler_desk_into_subagent_planes
    root = Dir.mktmpdir("rubik_vakanuvis_scope")
    begin
      source = Rubik::Tools::Registry.build_default(buffer_manager: Rubik::Buffer::Manager.new(root_dir: root), root_dir: root)
      registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
      # En geniş düzlem bile: her şeyden izinli custom tip (write + spawn
      # açık) — ROOT_ONLY seam'i yine de kronikçiyi dışarıda tutar.
      registry.define_custom(name: "greedy", description: "widest custom",
                             system_prompt: "x", enable_write_tools: true, enable_subagent_tools: true)
      ["research", "coder", "self", "greedy", "vakanuvis"].each do |type|
        scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
          source_registry: source, type_def: registry.get(type),
          child_ctx: nil, buffer: nil, parent_buffer: nil
        )
        names = scoped.list.map(&:name)
        refute_includes names, "vakanuvis", "'#{type}' plane must not see the chronicler tool (K7)"
      end

      self_scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
        source_registry: source, type_def: registry.get("self"),
        child_ctx: nil, buffer: nil, parent_buffer: nil
      )
      assert_includes self_scoped.list.map(&:name), "storage", "self keeps its full-clone toolbelt otherwise"
    ensure
      remove_temp_dir(root)
    end
  end

  def test_registry_hides_the_tool_until_the_coeffect_is_satisfied
    root = Dir.mktmpdir("rubik_vakanuvis_hide")
    begin
      ctx = Rubik::Runtime::Context.new
      source = Rubik::Tools::Registry.build_default(
        buffer_manager: Rubik::Buffer::Manager.new(root_dir: root), runtime_manager: nil, root_dir: root
      )
      hidden = Rubik::Tools::Registry.new(coeffect_ctx: ctx)
      source.list.each { |t| hidden.register(t) }
      refute_includes hidden.schemas.map { |s| s[:name] }, "vakanuvis",
                      "unsatisfied VAKANUIS coeffect must hide the tool (disabled chronicler)"

      ctx.provide(Rubik::Coeffects::VAKANUIS, @harness)
      assert_includes hidden.schemas.map { |s| s[:name] }, "vakanuvis"
      ctx.dispose
    ensure
      remove_temp_dir(root)
    end
  end

  class FakeHarness
    attr_reader :store, :dmesg

    def initialize(store)
      @store = store
      @dmesg = []
    end

    def recall(query, **)
      "recall output for #{query}"
    end

    def record(topic:, **)
      { "ref" => "mem.#{topic}", "skipped" => false, "version" => 1, "id" => "1" }
    end

    def forget(ref:)
      { "ref" => ref, "forgot" => true, "mode" => "supersede", "id" => "1" }
    end

    def digest(query)
      "digest output for #{query}"
    end
  end

  def test_delegates_actions_to_mocked_harness
    mock_store = Minitest::Mock.new
    mock_store.expect(:uri_for, "rubik://storage/proj/memory/1", ["memory", "1"])
    mock_store.expect(:uri_for, "rubik://storage/proj/memory/1", ["memory", "1"])
    fake_harness = FakeHarness.new(mock_store)

    t = tool(fake_harness)

    assert_equal "recall output for test query", t.execute({ "action" => "recall", "query" => "test query" })

    rec_out = t.execute({ "action" => "record", "topic" => "test", "body" => "body" })
    assert_includes rec_out, "Recorded 'mem.test': stored (version 1)."
    assert_includes rec_out, "URI: rubik://storage/proj/memory/1"

    for_out = t.execute({ "action" => "forget", "ref" => "mem.test" })
    assert_includes for_out, "Forgot 'mem.test': superseded (status + trace link kept)."

    assert_equal "digest output for digest query", t.execute({ "action" => "digest", "query" => "digest query" })

    mock_store.verify
  end

  def test_forget_reports_hard_purge
    mock_harness = Minitest::Mock.new
    mock_harness.expect(:forget, { "ref" => "mem.temp", "forgot" => true, "mode" => "purge" }, ref: "mem.temp")

    t = tool(mock_harness)
    out = t.execute({ "action" => "forget", "ref" => "mem.temp" })
    assert_equal "Forgot 'mem.temp': row purged (hard delete).", out
    mock_harness.verify
  end

  def test_rescues_standard_error_and_logs_to_dmesg
    mock_harness = Object.new
    def mock_harness.recall(_query, **)
      raise StandardError, "connection timeout"
    end

    def mock_harness.dmesg
      @dmesg ||= []
    end

    t = tool(mock_harness)
    out = t.execute({ "action" => "recall", "query" => "fail" })

    assert_includes out, "vakanuvis recall failed: StandardError: connection timeout"
    assert_includes out, "the store may be unavailable"
  end

  def test_resolves_harness_from_runtime_context_coeffect
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::VAKANUIS, @harness)

    t = tool(nil, runtime_context: ctx)
    @harness.record(topic: "coeffect test", body: "resolves via context")

    out = t.execute({ "action" => "recall", "query" => "coeffect" })
    assert_includes out, "coeffect test"
    ctx.dispose
  end

  def test_handles_symbol_keyed_arguments
    mock_harness = Minitest::Mock.new
    mock_harness.expect(:recall, "symbol result", ["sym query"], types: nil)

    t = tool(mock_harness)
    res = t.execute({ action: :recall, query: "sym query" })
    assert_equal "symbol result", res
    mock_harness.verify
  end
end
