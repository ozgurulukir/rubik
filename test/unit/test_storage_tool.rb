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

  def test_put_returns_id_uri_and_readback_hint
    out = tool.execute({ "action" => "put", "type" => "plan", "title" => "the plan", "body" => "steps", "ref" => "current" })
    assert_includes out, "plan.1."
    assert_includes out, "rubik://storage/toolproj/plan/plan.1."
    assert_includes out, "read_file"
    assert_equal "the plan", @store.get(type: "plan", id: "current")["title"], "ref must bind at put time"
  end

  def test_put_normalizes_comma_separated_tags
    tool.execute({ "action" => "put", "type" => "memory", "title" => "m", "tags" => "a, b ,,c" })
    record = @store.get(type: "memory", id: "1")
    assert_equal ["a", "b", "c"], record["tags"]
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

  def test_set_ref_and_delete_actions
    record = @store.put(type: "note", title: "n")
    out = tool.execute({ "action" => "set_ref", "ref" => "scratch", "id" => record["id"] })
    assert_includes out, "scratch → #{record['id']}"
    assert tool.execute({ "action" => "delete", "type" => "note", "id" => "1" }).start_with?("Deleted:")
    assert_nil @store.get(type: "note", id: "1")
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
