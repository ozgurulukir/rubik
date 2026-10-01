# frozen_string_literal: true

require_relative "../test_helper"

# ShowFileTool (storage-show-surface planı A): kalıcı depo varlığını
# kullanıcının terminaline doğrudan basar — içerik ToolOutput.display
# sarmalayıcısıyla işaretlenir, model yalnız stub görür.
class TestShowFileTool < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_show_store")
    @workdir = Dir.mktmpdir("rubik_show_ws")
    @store = Rubik::Storage::Store.new(root: @root, project: "showproj")
    @ctx = Rubik::Runtime::Context.new
    @ctx.provide(Rubik::Coeffects::STORAGE_STORE, @store)
    @tool = Rubik::Tools::ShowFileTool.new(runtime_context: @ctx)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@workdir) if @workdir && Dir.exist?(@workdir)
  end

  def test_non_storage_paths_are_refused_to_read_file
    out = @tool.execute({ "path" => "lib/main.rb" })
    assert out.is_a?(Rubik::Tools::ToolOutput) && out.error?, "filesystem paths stay with read_file"
    assert_includes out, "read_file"
    refute out.user_display?, "a refusal must never carry display payload"
  end

  def test_entity_renders_as_display_output_with_stub
    record = @store.put(type: "review", title: "Review report", body: "FINDING-1\nFINDING-2")
    out = @tool.execute({ "path" => "rubik://storage/showproj/review/#{record['id']}" })

    assert out.is_a?(Rubik::Tools::ToolOutput), "display contract rides the honest ToolOutput carrier"
    assert out.user_display?
    assert_includes out, "FINDING-1"
    assert_includes out.display_stub, "Rendered"
    assert_includes out.display_stub, record["id"], "stub keeps the address for follow-up questions"
    refute_includes out.display_stub, "FINDING-1", "the model is not fed the body"
  end

  def test_refs_alias_form_resolves
    @store.put(type: "review", title: "Reffed", body: "ALIAS-BODY", ref: "tangram-review")
    out = @tool.execute({ "path" => "rubik://storage/showproj/refs/tangram-review" })

    assert out.user_display?
    assert_includes out, "ALIAS-BODY"
    assert_includes out.display_stub, "refs/tangram-review", "the stub keeps the address the model asked with"
  end

  def test_unknown_entity_is_an_honest_error
    out = @tool.execute({ "path" => "rubik://storage/showproj/review/review.99.0000000000000000" })
    assert out.error?, "not-found stays a tool error, not a display"
  end

  def test_oversized_entity_falls_back_to_paging_guidance
    @store.put(type: "wiki", title: "Big", body: (1..(Rubik::Tools::ShowFileTool::MAX_DISPLAY_LINES + 1)).map { "l#{_1}" }.join("\n"))
    out = @tool.execute({ "path" => "rubik://storage/showproj/wiki/1" })

    assert out.error?
    assert_includes out, "read_file", "oversized entities redirect to paginated reads"
  end

  def test_single_huge_line_is_byte_capped
    # 400 satırın ALTINDA ama tek dev satır (minified JSON tarzı) — satır
    # kapısı geçilir, byte kapısı düşürür (review-round 2 bulgusu).
    blob = "x" * (Rubik::Tools::ShowFileTool::MAX_DISPLAY_BYTES + 1)
    @store.put(type: "note", title: "Blob", body: blob)
    out = @tool.execute({ "path" => "rubik://storage/showproj/note/1" })

    assert out.error?
    assert_includes out, "read_file"
  end
end
