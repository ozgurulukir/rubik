# frozen_string_literal: true

require_relative "../test_helper"

# Rubik::Storage::Vakanuvis::MemorySteward — memory kartlarının yazma disiplini
# (record), emeklilik politikası (forget — K2 supersede/purge) ve kaçak ham
# storage put'ların süpürülmesi (sweep_rogue_memory).
class TestVakanuvisMemorySteward < Minitest::Test
  S = Rubik::Storage::Vakanuvis::MemorySteward
  V = Rubik::Storage::Vakanuvis::Vocabulary

  def setup
    @root = Dir.mktmpdir("rubik_memory_steward_test")
    @store = Rubik::Storage::Store.new(root: @root, project: "Steward Test")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  # ---- Seam 1: record --------------------------------------------------------

  def test_record_creates_new_memory_record
    res = S.record(
      @store,
      topic: "  deploy  ",
      body: "Use capistrano",
      links: { "env" => "prod" }
    )
    assert_equal "mem.deploy", res["ref"]
    assert_equal 1, res["version"]
    refute res["skipped"]

    rec = @store.get(type: "memory", id: "mem.deploy")
    assert_equal "deploy", rec["title"]
    assert_equal "Use capistrano", rec["body"]
    assert_equal V::MEMORY_TAGS.sort, rec["tags"].sort
    assert_equal({ "env" => "prod" }, rec["links"])
  end

  def test_record_updates_existing_topic
    S.record(@store, topic: "deploy", body: "Use capistrano v1")
    res2 = S.record(@store, topic: "deploy", body: "Use capistrano v2")

    assert_equal "mem.deploy", res2["ref"]
    assert_equal 2, res2["version"]
    refute res2["skipped"]

    rec = @store.get(type: "memory", id: "mem.deploy")
    assert_equal "Use capistrano v2", rec["body"]
  end

  def test_record_skips_when_content_unmodified
    res1 = S.record(@store, topic: "deploy", body: "Use capistrano")
    res2 = S.record(@store, topic: "deploy", body: "Use capistrano")

    assert res2["skipped"]
    assert_equal res1["version"], res2["version"]
  end

  def test_record_validates_required_arguments
    assert_raises(ArgumentError) do
      S.record(@store, topic: "", body: "body")
    end

    assert_raises(ArgumentError) do
      S.record(@store, topic: "   ", body: "body")
    end

    assert_raises(ArgumentError) do
      S.record(@store, topic: "topic", body: "")
    end

    assert_raises(ArgumentError) do
      S.record(@store, topic: "topic", body: "   ")
    end
  end

  # ---- Seam 2: forget --------------------------------------------------------

  def test_forget_returns_false_when_ref_does_not_exist
    res = S.forget(@store, ref: "mem.nonexistent")
    assert_equal "mem.nonexistent", res["ref"]
    refute res["forgot"]
  end

  def test_forget_supersedes_by_default
    S.record(@store, topic: "deploy", body: "Use capistrano")
    res = S.forget(@store, ref: "mem.deploy")

    assert_equal "mem.deploy", res["ref"]
    assert res["forgot"]
    assert_equal "supersede", res["mode"]

    rec = @store.get(type: "memory", id: "mem.deploy")
    assert_equal V::STATUS_SUPERSEDED, rec["status"]
    assert_equal "forget", rec["links"]["superseded_by"]
  end

  def test_forget_purges_when_requested
    rec_info = S.record(@store, topic: "deploy", body: "Use capistrano")
    res = S.forget(@store, ref: "mem.deploy", retention: "purge")

    assert_equal "mem.deploy", res["ref"]
    assert res["forgot"]
    assert_equal "purge", res["mode"]

    assert_nil @store.get(type: "memory", id: rec_info["id"])
    assert_nil @store.refs["mem.deploy"]
  end

  # ---- Seam 3: sweep_rogue_memory --------------------------------------------

  def test_sweep_rogue_memory_returns_zero_when_no_rogues
    assert_equal 0, S.sweep_rogue_memory(@store)

    # Even with a bound memory record created through record()
    S.record(@store, topic: "deploy", body: "Use capistrano")
    assert_equal 0, S.sweep_rogue_memory(@store)
  end

  def test_sweep_rogue_memory_binds_winner_and_supersedes_older_rogues
    rec1 = @store.put(type: "memory", title: "Rogue Topic", body: "Rogue v1")
    rec2 = @store.put(type: "memory", title: "Rogue Topic", body: "Rogue v2") # winner: highest row

    assert_nil @store.refs["mem.rogue-topic"]

    swept = S.sweep_rogue_memory(@store)
    assert_equal 2, swept

    # Ref now points to winner rec2
    assert_equal rec2["id"], @store.refs["mem.rogue-topic"]

    # rec1 is superseded by winner id
    r1 = @store.get(type: "memory", id: rec1["id"])
    assert_equal V::STATUS_SUPERSEDED, r1["status"]
    assert_equal rec2["id"], r1["links"]["superseded_by"]
  end
end
