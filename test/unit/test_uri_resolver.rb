# frozen_string_literal: true

require_relative "../test_helper"

# Tools::UriResolver sevk yeri (uri-resolver-seam planı 2026-10-01):
# read_file/show_file'ın rubik:// tek geçişi. nil düşüş sözleşmesi
# (bilinmeyen şema/gramer reddi → çağıranın doğal düzlemi), `only:`
# kısıtı ve driver desenli geri-alınabilir kayıt (LIFO ters etkisi).
class TestUriResolver < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_uri_resolver")
    @workdir = Dir.mktmpdir("rubik_uri_resolver_ws")
    @store = Rubik::Storage::Store.new(root: @root, project: "seamproj")
    @ctx = Rubik::Runtime::Context.new
    @ctx.provide(Rubik::Coeffects::STORAGE_STORE, @store)
    @buffer = Rubik::Buffer::Manager.new(root_dir: @workdir)
  end

  def teardown
    @ctx.dispose
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
    FileUtils.remove_entry(@workdir) if @workdir && Dir.exist?(@workdir)
  end

  def resolve(uri, only: nil)
    Rubik::Tools::UriResolver.resolve(uri, ctx: @ctx, buffer_manager: @buffer, only: only)
  end

  def test_storage_entities_resolve_through_the_seam_with_index_refs_and_json_forms
    record = @store.put(type: "goal", title: "G1", body: "seam body", ref: "active-goal")
    assert_includes resolve("rubik://storage/index"), "Rubik storage central index"
    assert_includes resolve("rubik://storage/seamproj"), "Storage project: seamproj"
    assert_includes resolve("rubik://storage/seamproj/goal"), "| 1 | `#{record['id']}`"
    assert_includes resolve("rubik://storage/seamproj/goal/#{record['id']}"), "seam body"
    assert_includes resolve("rubik://storage/seamproj/refs/active-goal"), "# #{record['id']}"
    assert_includes resolve("rubik://storage/seamproj/goal/#{record['id']}.json"), record["hash"], "raw json form"
    assert_includes resolve("rubik://storage/goal/1"), "seam body", "default-project form"
  end

  def test_unknown_schemes_and_grammar_mismatches_fall_through_as_nil
    assert_nil resolve("rubik://storagefoo"), "scheme-like-but-not-storage falls through to the buffer plane"
    assert_nil resolve("rubik://subagent/"), "malformed subagent form falls through"
    assert_nil resolve("rubik://newthing/x"), "unregistered scheme falls through"
    assert_nil resolve("lib/main.rb"), "plain paths are not the resolver's concern"
  end

  def test_only_restricts_dispatch_to_one_scheme
    assert_nil resolve("rubik://storage/index", only: Rubik::Uris::GOAL),
               "storage URIs must not dispatch under a goal-only gate"
    assert_nil resolve("rubik://goal/state", only: Rubik::Uris::STORAGE),
               "goal URIs must not dispatch under a storage-only gate (show_file's refusal plane)"
    assert_includes resolve("rubik://storage/index", only: Rubik::Uris::STORAGE).to_s,
                    "Rubik storage central index", "the matching scheme still serves under only:"
  end

  def test_handles_reports_registered_schemes_only
    assert Rubik::Tools::UriResolver.handles?("rubik://storage/index")
    refute Rubik::Tools::UriResolver.handles?("rubik://storagefoo")
    refute Rubik::Tools::UriResolver.handles?("lib/main.rb")
    assert_includes Rubik::Tools::UriResolver.registered_schemes, Rubik::Uris::STORAGE
  end

  # Kayıt sözleşmesi Sandbox::Driver ile aynı (AGENTS.md §4.D): ctx'li kayıt
  # dispose'ta geri alınır, kimlik koruması daha yeni kaydı ezmez.
  class DemoAdapter
    def match?(uri)
      uri == "rubik://demo/x"
    end

    def read(_uri, ctx:, **_)
      Rubik::Tools::ToolOutput.error("demo ctx present: #{!ctx.nil?}")
    end
  end

  def test_plugin_adapter_registration_is_reverted_by_context_dispose
    ctx = Rubik::Runtime::Context.new
    Rubik::Tools::UriResolver.register("demo", DemoAdapter.new, ctx: ctx)
    assert Rubik::Tools::UriResolver.handles?("rubik://demo/x")
    assert_includes resolve("rubik://demo/x"), "demo ctx present: true"

    ctx.dispose
    refute Rubik::Tools::UriResolver.handles?("rubik://demo/x"), "dispose must unregister the plugin scheme"
    assert_nil resolve("rubik://demo/x"), "unregistered scheme falls through again"
  ensure
    Rubik::Tools::UriResolver.unregister("demo")
  end

  def test_re_registration_survives_an_older_context_dispose
    older = Rubik::Runtime::Context.new
    Rubik::Tools::UriResolver.register("demo", DemoAdapter.new, ctx: older)
    newer = DemoAdapter.new
    Rubik::Tools::UriResolver.register("demo", newer) # global registration, no ctx

    older.dispose
    assert Rubik::Tools::UriResolver.handles?("rubik://demo/x"),
           "the newer registration owns the slot and must survive the older context's teardown"
  ensure
    Rubik::Tools::UriResolver.unregister("demo")
  end

  def test_overlay_registration_over_builtin_restores_builtin_on_dispose
    builtin = Rubik::Tools::UriResolver::DEFAULT_STORAGE_ADAPTER
    ctx = Rubik::Runtime::Context.new
    Rubik::Tools::UriResolver.register("storage", DemoAdapter.new, ctx: ctx)
    assert_nil resolve("rubik://storage/index"),
               "while the overlay holds the slot, the default storage grammar does not serve"

    ctx.dispose
    assert Rubik::Tools::UriResolver.handles?("rubik://storage/index"),
           "disposing an overlay must restore the default storage adapter underneath"
    assert_includes resolve("rubik://storage/index"), "Rubik storage central index"
  ensure
    Rubik::Tools::UriResolver.register(Rubik::Uris::STORAGE, builtin) unless
      Rubik::Tools::UriResolver.handles?("rubik://storage/index")
  end
end
