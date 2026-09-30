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
