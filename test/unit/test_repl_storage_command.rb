# frozen_string_literal: true

require_relative "../test_helper"

# !storage REPL komutu (storage-show-surface planı B): kullanıcının merkezi
# depoya modelsiz bakışı — özet, refs tablosu, tip listesi ve çapraz-tip
# seçici çözümü (tam id → type.row → row → hash öneki → alias).
class TestReplStorageCommand < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage_cmd")
    @store = Rubik::Storage::Store.new(root: @root, project: "cmdproj")
    @ctx = Rubik::Runtime::Context.new
    @ctx.provide(Rubik::Coeffects::STORAGE_STORE, @store)
    @out = StringIO.new
    @shell = Object.new
    @shell.define_singleton_method(:register_command) { |*_args, **_kw, &blk| @handler = blk }
    @shell.instance_variable_set(:@handler, nil)
    Rubik::REPL::Commands::Storage.register(@shell)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def run_cmd(*args)
    ctx_obj = @ctx
    rt = Object.new
    rt.define_singleton_method(:context) { ctx_obj }
    ctx = Struct.new(:out, :runtime_manager).new(@out, rt)
    @shell.instance_variable_get(:@handler).call(args, ctx)
    @out.string
  end

  def seed
    @review = @store.put(type: "review", title: "Review report", body: "REVIEW-BODY", ref: "tangram-review")
    @note = @store.put(type: "note", title: "A note", body: "NOTE-BODY")
  end

  def test_summary_when_no_args
    seed
    out = run_cmd
    assert_includes out, "Storage project: cmdproj"
    assert_includes out, "tangram-review → #{@review['id']}", "refs are surfaced without asking"
  end

  def test_refs_table
    seed
    out = run_cmd("refs")
    assert_includes out, "tangram-review → #{@review['id']}"
    assert_includes out, "Refs in 'cmdproj'"
  end

  def test_empty_refs_is_honest
    out = run_cmd("refs")
    assert_includes out, "No refs defined"
  end

  def test_type_listing_marks_refs
    seed
    out = run_cmd("review")
    assert_includes out, "cmdproj/review"
    assert_includes out, "tangram-review", "the listing points at the alias"
    assert_includes out, @review["id"]
  end

  def test_selector_resolution_by_ref_alias_and_row
    seed
    assert_includes run_cmd("tangram-review"), "REVIEW-BODY", "alias selector"
    assert_includes run_cmd(@review["id"]), "REVIEW-BODY", "full-id selector"
    assert_includes run_cmd("review.1"), "REVIEW-BODY", "type.row selector"
    assert_includes run_cmd("1"), "REVIEW-BODY", "row selector"

    card = run_cmd("tangram-review")
    assert_includes card, "ref: tangram-review", "the card names the alias"
    assert_includes card, "rubik://storage/cmdproj/review/#{@review['id']}"
  end

  def test_unknown_selector_is_honest_with_guidance
    seed
    out = run_cmd("nope.42.deadbeefdeadbeef")
    assert_includes out, "not found"
    assert_includes out, "!storage refs", "guidance teaches the other views"
  end

  def test_missing_store_fails_closed
    rt = Object.new
    rt.define_singleton_method(:context) { Rubik::Runtime::Context.new }
    ctx = Struct.new(:out, :runtime_manager).new(@out, rt)
    @shell.instance_variable_get(:@handler).call([], ctx)
    assert_includes @out.string, "not available"
  end
end
