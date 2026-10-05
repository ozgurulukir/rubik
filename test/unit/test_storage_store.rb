# frozen_string_literal: true

require_relative "../test_helper"

# Rubik::Storage::Store — merkezi sanal FS-DB çekirdeği: id/row/karma
# kimlikleri, çözüm formları, refs, arama, indeks, izolasyon, tembellik.
class TestStorageStore < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rubik_storage")
    @store = Rubik::Storage::Store.new(root: @root, project: "Demo Proj!")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  def test_put_mints_row_and_hash_identity
    record = @store.put(type: "goal", title: "Ship it", body: "body text", tags: ["alpha", "beta"])
    assert_match(/\Agoal\.1\.[0-9a-f]{16}\z/, record["id"])
    assert_equal 1, record["row"]
    assert_equal 1, record["version"]
    assert_equal "demo-proj", @store.project
    assert_equal 64, record["hash"].length
  end

  def test_get_resolves_every_id_form
    record = @store.put(type: "plan", title: "p1", body: "x")
    full_id = record["id"]
    assert_equal full_id, @store.get(type: "plan", id: full_id)["id"]
    assert_equal full_id, @store.get(type: "plan", id: "plan.1")["id"]
    assert_equal full_id, @store.get(type: "plan", id: "1")["id"]
    assert_equal full_id, @store.get(type: "plan", id: record["hash"][0, 12])["id"]
    assert_nil @store.get(type: "plan", id: "99")
    assert_nil @store.get(type: "plan", id: "goal.1")
  end

  def test_update_keeps_id_and_bumps_version_and_hash
    first = @store.put(type: "wiki", title: "t", body: "v1")
    second = @store.put(type: "wiki", title: "t", body: "v2", id: first["id"])
    assert_equal first["id"], second["id"], "row is the stable address — refs/links never break"
    assert_equal 2, second["version"]
    refute_equal first["hash"], second["hash"], "hash tracks current content"
    assert_equal "v2", @store.get(type: "wiki", id: first["id"])["body"]
  end

  def test_update_of_unknown_id_raises
    error = assert_raises(ArgumentError) do
      @store.put(type: "plan", title: "x", id: "plan.9.0000000000000000")
    end
    assert_match(/not found/, error.message)
  end

  def test_rows_are_monotonic_and_never_reused_after_delete
    @store.put(type: "note", title: "n1")
    @store.put(type: "note", title: "n2")
    assert @store.delete(type: "note", id: "2")
    third = @store.put(type: "note", title: "n3")
    assert_equal 3, third["row"], "deleted row numbers must never be reused"
    assert_equal 2, @store.list(type: "note").length
  end

  def test_refs_bind_overwrite_and_drop_on_delete
    @store.put(type: "plan", title: "a", ref: "current-plan")
    second = @store.put(type: "plan", title: "b", ref: "current-plan")
    assert_equal second["id"], @store.refs["current-plan"], "ref upserts to the newest entity"
    assert_equal second["id"], @store.get(type: "plan", id: "current-plan")["id"], "aliases resolve in get"
    @store.delete(type: "plan", id: second["id"])
    assert_nil @store.refs["current-plan"], "refs to deleted entities are dropped"
  end

  def test_search_covers_title_body_and_tags_casefold
    @store.put(type: "memory", title: "Deploy keys", body: "rotate QUARTERLY", tags: ["ops"])
    @store.put(type: "memory", title: "other", body: "unrelated")
    assert_equal 1, @store.search(query: "deploy").length
    assert_equal 1, @store.search(query: "quarterly").length
    assert_equal 1, @store.search(query: "OPS").length
    assert_equal 0, @store.search(query: "nope").length
  end

  def test_search_matches_records_containing_every_query_token
    @store.put(type: "note", title: "ratelimit-lock incident",
               body: "regression 11/11 fixed upstream", tags: ["flaky"])
    @store.put(type: "note", title: "ratelimit-lock only", body: "no regression here")
    @store.put(type: "note", title: "unrelated", body: "nothing to see")

    # Olay #2 (2026-10-04): çok kelimeli doğal sorgu tek substring olarak
    # aranıyordu ve hiçbir kayıtla kelimesi kelimesine eşleşmiyordu.
    hits = @store.search(query: "ratelimit-lock regression 11/11")
    assert_equal 1, hits.length, "records carrying all tokens must match, in any field"
    assert_equal "ratelimit-lock incident", hits.first["title"]

    assert_equal 0, @store.search(query: "ratelimit-lock unrelated").length,
                 "a record missing any token must not match (AND semantics)"
    assert_equal 0, @store.search(query: "   ").length, "blank queries stay empty"
  end

  def test_search_scopes_to_a_type_array_without_other_types
    @store.put(type: "memory", title: "gateway cold start", body: "lesson text")
    @store.put(type: "transcript", title: "gateway cold start transcript", body: "noise")
    @store.put(type: "wiki", title: "gateway page", body: "compiled")

    hits = @store.search(query: "gateway", type: ["memory", "wiki"])
    assert_equal ["memory", "wiki"], hits.map { |r| r["type"] }, "array type scoping must skip transcripts entirely"
    assert_equal 1, @store.search(query: "gateway", type: "transcript").length,
                 "single-string type form keeps working (storage tool seam)"
  end

  def test_parsed_records_cache_reuses_and_self_heals
    @store.put(type: "memory", title: "cached", body: "one")
    first = @store.send(:load_records, "memory")
    assert_same first, @store.send(:load_records, "memory"), "unchanged mtime must serve the cached parse"

    @store.put(type: "memory", title: "invalidated", body: "two")
    refute_same first, @store.send(:load_records, "memory"), "a write must drop the cache"
    assert_equal 2, @store.search(query: "cached").size + @store.search(query: "invalidated").size

    # Dış müdahale (başka süreç / elle düzenleme): mtime değişince cache
    # kendini onarır — bayat serve yok.
    path = File.join(@root, @store.project, "store", "memory.jsonl")
    File.open(path, "a") do |f|
      f.puts JSON.generate("id" => "memory.99.ffffffffffffffff", "type" => "memory",
                           "title" => "external append", "body" => "three", "tags" => [],
                           "links" => {}, "row" => 99, "version" => 1)
    end
    File.utime(0, Time.now + 2, path) # NTFS hızında mtime farkını garanti et
    assert_equal 1, @store.search(query: "external append").length, "mtime revalidation must see external writes"
  end

  def test_reads_are_utf8_pinned_under_a_non_utf8_external_encoding
    # vakanuvis-v2 planı §4-V7: depo dosyaları UTF-8 yazılır ama okumalar işlem
    # dış kodlamasına emanetti — TR Windows yerelinde (cp1254) yanlış etiketli
    # haystack, ASCII olmayan recall sorgusunda CompatibilityError üretiyordu.
    @store.put(type: "memory", title: "Docker MCP Gateway",
               body: "soğuk başlatma zaman aşımı dersi", tags: ["ops"])

    before = Encoding.default_external
    Encoding.default_external = Encoding::Windows_1254
    begin
      cold = Rubik::Storage::Store.new(root: @root, project: @store.project)
      hits = cold.search(query: "soğuk başlatma")
      assert_equal 1, hits.length, "UTF-8-pinned reads keep Turkish queries matching under a cp1254 locale"
      assert_equal Encoding::UTF_8, hits.first["body"].encoding, "parsed rows must come back UTF-8-tagged"
    ensure
      Encoding.default_external = before
    end
  end

  def test_subagent_selector_resolves_legacy_double_prefixed_alias
    # Olay #4 (2026-10-04): eski depolarda transcript alias'ı çift önekle
    # basılmıştı ("subagent-subagent-..."). Doğal form, legacy anahtarı
    # çözmeli — completion-time upsert böylece eski satırı bulur, kopya açmaz.
    legacy = @store.put(type: "transcript", title: "t1", ref: "subagent-subagent-1-8611")

    assert_equal legacy["id"], @store.get(type: "transcript", id: "subagent-1-8611")["id"],
                 "natural subagent-<id> form resolves the legacy double-prefixed alias"
    assert_equal legacy["id"], @store.get(type: "transcript", id: "subagent-subagent-1-8611")["id"],
                 "the stored alias form keeps resolving as-is"

    fresh = @store.put(type: "transcript", title: "t2", ref: "subagent-2-9000")
    assert_equal fresh["id"], @store.get(type: "transcript", id: "subagent-2-9000")["id"],
                 "new-style single-prefix aliases resolve directly"
  end

  def test_list_summaries_are_sorted_and_shaped
    @store.put(type: "goal", title: "g")
    @store.put(type: "plan", title: "p")
    summaries = @store.list
    assert_equal(["goal", "plan"], summaries.map { |s| s[:id].split(".").first })
    summary = @store.list(type: "goal").first
    assert_equal "g", summary[:title]
    assert_equal 1, summary[:row]
  end

  def test_projects_are_isolated_and_share_the_central_index
    other = Rubik::Storage::Store.new(root: @root, project: "other")
    mine = @store.put(type: "goal", title: "mine")
    other.put(type: "goal", title: "theirs")
    assert_nil other.get(type: "goal", id: mine["id"]), "stores only see their own project"
    snapshot = Rubik::Storage::Store.index_snapshot(@root)
    assert_equal({ "goal" => 1 }, snapshot["projects"]["demo-proj"]["entity_counts"])
    assert_equal({ "goal" => 1 }, snapshot["projects"]["other"]["entity_counts"])
  end

  def test_construction_and_reads_touch_no_filesystem
    lazy_root = File.join(@root, "lazy")
    fresh = Rubik::Storage::Store.new(root: lazy_root, project: "p")
    assert_equal [], fresh.list
    assert_nil fresh.get(type: "goal", id: "1")
    assert_equal({}, fresh.refs)
    refute Dir.exist?(lazy_root), "lazy store must not create directories on read"
    fresh.put(type: "goal", title: "now")
    assert Dir.exist?(File.join(lazy_root, "p", "store"))
  end

  def test_concurrent_puts_allocate_distinct_rows
    threads = Array.new(8) do |i|
      Thread.new do
        5.times { |j| @store.put(type: "note", title: "t#{i}-#{j}") }
      end
    end
    threads.each(&:join)
    rows = @store.list(type: "note").map { |s| s[:row] }.sort
    assert_equal (1..40).to_a, rows, "monitor must serialize row allocation — no duplicates, no gaps"
  end

  def test_unknown_type_and_blank_title_are_rejected
    assert_raises(ArgumentError) { @store.put(type: "bogus", title: "x") }
    assert_raises(ArgumentError) { @store.put(type: "goal", title: "  ") }
  end

  def test_project_summary_reports_counts_and_refs
    @store.put(type: "goal", title: "g", ref: "the-goal")
    summary = @store.project_summary
    assert_equal({ "goal" => 1 }, summary["entity_counts"])
    assert_equal "the-goal", summary["refs"].keys.first
    assert_equal @store.project_dir, summary["path"]
  end

  def test_content_hash_is_deterministic_and_normalizes_tag_order
    a = @store.put(type: "memory", title: "t", body: "b", tags: ["x", "y"])
    b = Rubik::Storage::Store.new(root: @root, project: "hashcheck")
                             .put(type: "memory", title: "t", body: "b", tags: ["y", "x"])
    assert_equal a["hash"], b["hash"], "canonical hashing normalizes tag order"
  end
end
