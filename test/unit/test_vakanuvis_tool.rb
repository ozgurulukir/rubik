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

  def test_forget_reports_trace_and_missing_ref_honestly
    tool.execute({ "action" => "record", "topic" => "temp fact", "body" => "scratch" })
    out = tool.execute({ "action" => "forget", "ref" => "mem.temp-fact" })
    assert_includes out, "superseded (status + trace link kept)"

    missing = tool.execute({ "action" => "forget", "ref" => "mem.nothing" })
    assert_includes missing, "Nothing to forget"
  end

  def test_digest_receipt_is_deterministic_and_names_the_target_ref
    first = tool.execute({ "action" => "digest", "query" => "release pipeline" })
    second = tool.execute({ "action" => "digest", "query" => "release pipeline" })
    assert_equal first, second, "same request must return the identical receipt (async contract)"
    assert_includes first, "Digest queued (async)", "the maestro must know the compile happens later, async"
    assert_includes first, "wiki.release-pipeline", "receipt names the deterministic target ref"
    assert_includes first, "No distiller run started yet",
                    "without a distiller (this harness has no supervisor) the receipt says so honestly"
  end

  def test_error_paths_are_empathetic_not_silent
    out = tool.execute({ "action" => "recall", "query" => "   " })
    assert_includes out, "vakanuvis recall", "ArgumentError surfaces with the action named"

    unknown = tool.execute({ "action" => "purge", "ref" => "mem.x" })
    assert_includes unknown, "Unknown vakanuvis action 'purge'"
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
end
