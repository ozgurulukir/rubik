# frozen_string_literal: true

require_relative "../test_helper"

# storage aracı (yazma düzlemi) — eylemler, üçlü çözüm zinciri (enjekte →
# coeffect → config fresh), etiket normalizasyonu, dürüst hatalar.
class TestStorageTool < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage_tool")
    @store = Rubik::Storage::Store.new(root: @root, project: "toolproj")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def tool(store = @store, runtime_context: nil, config: nil)
    Rubik::Tools::StorageTool.new(store, runtime_context: runtime_context, config: config, root_dir: @root)
  end

  def test_requires_declares_the_storage_coeffect
    assert_equal [Rubik::Coeffects::STORAGE_STORE], Rubik::Tools::StorageTool::REQUIRES
  end

  def test_declaration_metadata
    decl = Rubik::Tools::StorageTool::DECLARATION
    assert_equal "storage", decl.name
    assert_includes decl.aliases, "rubik_storage"
    assert_equal :write, decl.risk
    assert decl.write_grant
    refute decl.maestro_blocked
    assert_equal Rubik::Storage::Store::TYPES, decl.params_schema[:properties][:type][:enum]
  end

  def test_default_action_is_list
    @store.put(type: "note", title: "default list note")
    out = tool.execute({})
    assert_includes out, "default list note"
  end

  def test_symbol_keys_support
    out = tool.execute({ action: :put, type: :note, title: "symbol key note", body: "symbol body" })
    assert_includes out, "note.1."
    assert_equal "symbol key note", @store.get(type: "note", id: "1")["title"]
  end

  def test_put_returns_id_uri_and_readback_hint
    out = tool.execute({ "action" => "put", "type" => "plan", "title" => "the plan", "body" => "steps", "ref" => "current" })
    assert_includes out, "plan.1."
    assert_includes out, "rubik://storage/toolproj/plan/plan.1."
    assert_includes out, "read_file"
    assert_equal "the plan", @store.get(type: "plan", id: "current")["title"], "ref must bind at put time"
  end

  def test_put_json_format_and_extended_attributes
    out = tool.execute(
      {
        "action" => "put",
        "type" => "plan",
        "title" => "Structured Plan",
        "body" => "step 1",
        "status" => "draft",
        "tags" => ["dev", "testing"],
        "links" => { "goal" => "goal.1.hash" },
        "format" => "json"
      }
    )
    parsed = JSON.parse(out)
    assert_equal "Structured Plan", parsed["title"]
    assert_equal "draft", parsed["status"]
    assert_equal ["dev", "testing"], parsed["tags"]
    assert_equal({ "goal" => "goal.1.hash" }, parsed["links"])
  end

  def test_put_normalizes_comma_separated_tags
    tool.execute({ "action" => "put", "type" => "memory", "title" => "m", "tags" => "a, b ,,c" })
    record = @store.get(type: "memory", id: "1")
    assert_equal ["a", "b", "c"], record["tags"]
  end

  def test_put_rejects_boolean_json_tags_with_a_clean_tool_error
    out = tool.execute({ "action" => "put", "type" => "wiki", "title" => "corrupt page", "tags" => [false, true] })
    assert_includes out, "storage put:"
    assert_includes out, "tags must be strings"
    assert_includes out, "FalseClass"
    assert_empty @store.list(type: "wiki"), "no corrupted row may land"
  end

  def test_put_rejects_top_level_scalar_tags_without_stringifying_them
    out = tool.execute({ "action" => "put", "type" => "note", "title" => "scalar tags", "tags" => true })
    assert_includes out, "storage put:"
    assert_includes out, "array of strings or a comma-separated string"
    assert_empty @store.list(type: "note"), "no \"true\" tag may land via the scalar fallback"

    falsy = tool.execute({ "action" => "put", "type" => "note", "title" => "falsy tags", "tags" => false })
    assert_includes falsy, "storage put:", "tags: false is a present key, not an absent one"
    assert_empty @store.list(type: "note")
  end

  def test_wiki_delete_rebuilds_the_home_index_immediately
    @store.put(type: "wiki", title: "Gateway page", body: "gateways need retry", ref: "wiki.gateway-page")
    Rubik::Storage::Vakanuvis::WikiSkeleton.rebuild_home(@store)
    assert_includes @store.get(type: "wiki", id: "wiki.home")["body"], "Gateway page"

    tool.execute({ "action" => "delete", "type" => "wiki", "id" => "wiki.gateway-page" })
    refute_includes @store.get(type: "wiki", id: "wiki.home")["body"], "Gateway page",
                    "the stale home entry must not outlive the row it points at"

    @store.put(type: "note", title: "plain note")
    out = tool.execute({ "action" => "delete", "type" => "note", "id" => "1" })
    assert_includes out, "Deleted:", "non-wiki deletes are untouched"
  end

  def test_home_rebuild_failure_after_wiki_delete_never_masks_the_delete_result
    real = @store
    rec = real.put(type: "wiki", title: "fleeting", body: "body")
    flaky = Object.new
    flaky.define_singleton_method(:method_missing) { |name, *a, **k, &b| real.send(name, *a, **k, &b) }
    flaky.define_singleton_method(:respond_to_missing?) { |*a| real.respond_to?(*a) }
    flaky.define_singleton_method(:list) { |**| raise "nope" }

    out = tool(flaky).execute({ "action" => "delete", "type" => "wiki", "id" => rec["id"] })
    assert_includes out, "Deleted:", "the delete result survives the failed home rebuild"
    assert_nil real.get(type: "wiki", id: rec["id"]), "the row is really gone"
  end

  def test_deleting_the_home_row_itself_does_not_resurrect_it
    @store.put(type: "wiki", title: "Gateway page", body: "gateways need retry", ref: "wiki.gateway-page")
    Rubik::Storage::Vakanuvis::WikiSkeleton.rebuild_home(@store)
    home_before = @store.get(type: "wiki", id: "wiki.home")

    out = tool.execute({ "action" => "delete", "type" => "wiki", "id" => "wiki.home" })
    assert_includes out, "Deleted:", "deleting wiki.home is a legal, honored request"
    assert_nil @store.get(type: "wiki", id: home_before["id"]),
               "the rebuild must not silently resurrect the row the delete just removed"
  end

  def test_get_renders_markdown_and_json
    record = @store.put(type: "goal", title: "G", body: "body text")
    markdown = tool.execute({ "action" => "get", "type" => "goal", "id" => record["id"] })
    assert_includes markdown, "# #{record['id']}"
    assert_includes markdown, "body text"
    json = JSON.parse(tool.execute({ "action" => "get", "type" => "goal", "id" => "1", "format" => "json" }))
    assert_equal "G", json["title"]
  end

  def test_list_and_search_actions
    @store.put(type: "plan", title: "alpha plan")
    @store.put(type: "plan", title: "beta plan")
    listing = tool.execute({ "action" => "list", "type" => "plan" })
    assert_includes listing, "alpha plan"
    assert_includes listing, "rubik://storage/toolproj/plan/<id>"
    assert_equal 1, tool.execute({ "action" => "search", "query" => "BETA" }).lines.length
    assert_equal "No storage entities match 'zzz'.", tool.execute({ "action" => "search", "query" => "zzz" })
  end

  def test_list_json_format
    @store.put(type: "goal", title: "Goal 1")
    @store.put(type: "plan", title: "Plan 1")
    out = tool.execute({ "action" => "list", "type" => "goal", "format" => "json" })
    parsed = JSON.parse(out)
    assert_equal 1, parsed.length
    assert_equal "Goal 1", parsed.first["title"]
  end

  def test_search_validation_and_json_format
    err = tool.execute({ "action" => "search", "query" => "   " })
    assert_includes err, "query' is required"

    @store.put(type: "wiki", title: "Spatiotemporal Systems")
    out = tool.execute({ "action" => "search", "query" => "spatiotemporal", "format" => "json" })
    parsed = JSON.parse(out)
    assert_equal 1, parsed.length
    assert_equal "Spatiotemporal Systems", parsed.first["title"]
  end

  def test_set_ref_and_delete_actions
    record = @store.put(type: "note", title: "n")
    out = tool.execute({ "action" => "set_ref", "ref" => "scratch", "id" => record["id"] })
    assert_includes out, "scratch → #{record['id']}"
    assert tool.execute({ "action" => "delete", "type" => "note", "id" => "1" }).start_with?("Deleted:")
    assert_nil @store.get(type: "note", id: "1")
  end

  def test_delete_non_existent_entity_returns_error
    out = tool.execute({ "action" => "delete", "type" => "note", "id" => "999" })
    assert_includes out, "Entity not found: note/999"
  end

  def test_handles_standard_error_during_execution
    exploding_store = Object.new
    def exploding_store.list(*)
      raise StandardError, "database file corrupt"
    end

    t = Rubik::Tools::StorageTool.new(exploding_store, root_dir: @root)
    out = t.execute({ "action" => "list" })
    assert_includes out, "storage error: StandardError: database file corrupt"
  end

  def test_coffect_resolution_via_runtime_context_parent_chain
    ctx = Rubik::Runtime::Context.new
    ctx.provide(Rubik::Coeffects::STORAGE_STORE, @store)
    child = ctx.extend
    # Enjekte edilen store nil: yalnız coeffect zinciri çözmeli.
    resolved = tool(nil, runtime_context: child)
    out = resolved.execute({ "action" => "put", "type" => "goal", "title" => "via ctx" })
    assert_includes out, "rubik://storage/toolproj/goal/"
    assert_equal "via ctx", @store.get(type: "goal", id: "1")["title"]
  end

  def test_fresh_default_from_config_when_no_store_wired
    config = { "storage" => { "enabled" => true, "root" => @root, "project" => "freshproj" } }
    out = tool(nil, config: config).execute({ "action" => "put", "type" => "goal", "title" => "fresh" })
    assert_includes out, "rubik://storage/freshproj/goal/"
  end

  def test_disabled_storage_reports_honestly
    config = { "storage" => { "enabled" => false } }
    out = tool(nil, config: config).execute({ "action" => "list" })
    assert_includes out, "Storage is not available"
  end

  def test_unknown_action_and_argument_errors_surface
    assert_includes tool.execute({ "action" => "bogus" }), "Unknown storage action 'bogus'"
    assert_includes tool.execute({ "action" => "put", "type" => "nope", "title" => "x" }), "unknown entity type"
    assert_includes tool.execute({ "action" => "get", "type" => "goal", "id" => "9" }), "not found"
  end
end
