# frozen_string_literal: true

require_relative "../test_helper"

# MemorySteward unit test suite: mühimme küratörlüğünün yazma disiplini (record),
# emeklilik politikası (forget — supersede/purge) ve kaçak ham storage put'larının
# süpürülmesi (sweep_rogue_memory) davranışlarını ve depo çağrı dizilimini doğrular.
class TestVakanuvisMemorySteward < Minitest::Test
  MS = Rubik::Storage::Vakanuvis::MemorySteward
  V = Rubik::Storage::Vakanuvis::Vocabulary

  def setup
    @root = Dir.mktmpdir("rubik_memory_steward_test")
    @store = Rubik::Storage::Store.new(root: @root, project: "steward_test")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && Dir.exist?(@root)
  end

  # ---- 1. record argument validation ------------------------------------

  def test_record_requires_topic
    err = assert_raises(ArgumentError) { MS.record(@store, topic: "", body: "content") }
    assert_includes err.message, "topic"

    err = assert_raises(ArgumentError) { MS.record(@store, topic: "   ", body: "content") }
    assert_includes err.message, "topic"

    err = assert_raises(ArgumentError) { MS.record(@store, topic: nil, body: "content") }
    assert_includes err.message, "topic"
  end

  def test_record_requires_body
    err = assert_raises(ArgumentError) { MS.record(@store, topic: "topic", body: "") }
    assert_includes err.message, "body"

    err = assert_raises(ArgumentError) { MS.record(@store, topic: "topic", body: "   ") }
    assert_includes err.message, "body"

    err = assert_raises(ArgumentError) { MS.record(@store, topic: "topic", body: nil) }
    assert_includes err.message, "body"
  end

  # ---- 2. record behavior (create, update, idempotent, links) ----------

  def test_record_creates_new_memory_card
    res = MS.record(@store, topic: "Release Checklist", body: "- Step 1: Tests\n- Step 2: Tag")

    assert_equal "mem.release-checklist", res["ref"]
    refute_nil res["id"]
    assert_equal 1, res["version"]
    refute res["skipped"]
    assert res["keywords_extracted"], "a body without a Keywords: line is auto-repaired"

    # Verify state in store
    rec = @store.get(type: "memory", id: res["ref"])
    assert_equal res["id"], rec["id"]
    assert_equal "Release Checklist", rec["title"]
    assert_match(/\A- Step 1: Tests\n- Step 2: Tag\n\nKeywords: /, rec["body"],
                 "the original body is preserved and the Keywords line appended")
    assert_equal V::MEMORY_TAGS.sort, rec["tags"]
    assert_equal V::STATUS_ACTIVE, rec["status"]
  end

  def test_record_updates_existing_memory_card
    res1 = MS.record(@store, topic: "Release Checklist", body: "v1")
    res2 = MS.record(@store, topic: "Release Checklist", body: "v2 updated")

    assert_equal res1["ref"], res2["ref"]
    assert_equal res1["id"], res2["id"]
    assert_equal 2, res2["version"]
    refute res2["skipped"]

    rec = @store.get(type: "memory", id: res1["ref"])
    assert_match(/\Av2 updated(\n\nKeywords: .*)?\z/, rec["body"])
  end

  def test_record_is_idempotent_when_content_unchanged
    res1 = MS.record(@store, topic: "Release Checklist", body: "v1")
    res2 = MS.record(@store, topic: "Release Checklist", body: "v1")

    assert_equal res1["ref"], res2["ref"]
    assert_equal res1["id"], res2["id"]
    assert_equal res1["version"], res2["version"]
    assert res2["skipped"], "duplicate content record should be marked skipped"
  end

  def test_record_persists_custom_links
    links = { "author" => "maestro", "issue" => "123" }
    res = MS.record(@store, topic: "Release Checklist", body: "body", links: links)

    rec = @store.get(type: "memory", id: res["ref"])
    assert_equal "maestro", rec["links"]["author"]
    assert_equal "123", rec["links"]["issue"]
  end

  # ---- 2b. record tags + Keywords repair (issue #99 P1) -----------------

  def test_record_merges_user_tags_with_the_memory_vocabulary_deduplicated
    res = MS.record(@store, topic: "Tagged", body: "content", tags: ["vakanuvis", "infra"])
    rec = @store.get(type: "memory", id: res["ref"])
    assert_equal(["infra", "memory", "vakanuvis"], rec["tags"])
    assert res["keywords_extracted"], "'content' has no Keywords: line — extracted"
  end

  def test_record_rejects_non_string_user_tags_without_touching_the_store
    err = assert_raises(ArgumentError) { MS.record(@store, topic: "Bad", body: "content", tags: [true]) }
    assert_includes err.message, "tags must be strings"
    assert_empty @store.list(type: "memory"), "failed record must not open a row"
  end

  def test_record_appends_a_deterministic_keywords_line_when_the_body_has_none
    body = "rotate the deploy keys quarterly; deploy runs after the handshake"
    first, = MS.ensure_keywords(body, title: "deploy keys")
    second, = MS.ensure_keywords(body, title: "deploy keys")
    assert_equal first, second, "same body must always yield the same Keywords line"
    assert_match(/\A#{Regexp.escape(body)}\n\nKeywords: deploy; keys; /, first,
                 "the original body is kept and frequency-ranked terms lead the line")
  end

  def test_record_keeps_an_existing_keywords_line_untouched_regardless_of_case
    body = "content\nKeywords: deploy; keys; release; pipeline; gates; tag"
    repaired, extracted = MS.ensure_keywords(body, title: "t")
    assert_equal body, repaired
    refute extracted

    upper, extracted_upper = MS.ensure_keywords("content\nKEYWORDS: a; b", title: "t")
    assert_equal "content\nKEYWORDS: a; b", upper
    refute extracted_upper
  end

  def test_extraction_skips_stopwords_short_tokens_and_ranks_by_frequency
    terms = MS.extract_terms("the gateway handshake retry retry gateway lock it of")
    assert_equal(["gateway", "retry", "handshake", "lock"], terms,
                 "stopwords and short tokens are gone; frequency leads, first occurrence breaks ties")
  end

  # ---- 3. forget behavior (missing, supersede, purge) ------------------

  def test_forget_returns_false_for_non_existent_ref
    res = MS.forget(@store, ref: "mem.non-existent")
    assert_equal "mem.non-existent", res["ref"]
    refute res["forgot"]
  end

  def test_forget_supersedes_record_by_default
    rec_info = MS.record(@store, topic: "Temporary Note", body: "to be forgotten")
    ref = rec_info["ref"]

    res = MS.forget(@store, ref: ref)
    assert_equal ref, res["ref"]
    assert_equal rec_info["id"], res["id"]
    assert res["forgot"]
    assert_equal "supersede", res["mode"]

    # Verify store record is marked superseded with superseded_by link
    rec = @store.get(type: "memory", id: rec_info["id"])
    refute_nil rec
    assert_equal V::STATUS_SUPERSEDED, rec["status"]
    assert_equal "forget", rec["links"]["superseded_by"]
  end

  def test_forget_purges_record_when_retention_is_purge
    rec_info = MS.record(@store, topic: "Secrets", body: "sensitive info")
    ref = rec_info["ref"]

    res = MS.forget(@store, ref: ref, retention: "purge")
    assert_equal ref, res["ref"]
    assert_equal rec_info["id"], res["id"]
    assert res["forgot"]
    assert_equal "purge", res["mode"]

    # Record should be completely gone
    assert_nil @store.get(type: "memory", id: rec_info["id"])
    assert_nil @store.get(type: "memory", id: ref)
  end

  # ---- 4. sweep_rogue_memory --------------------------------------------

  def test_sweep_rogue_memory_returns_zero_on_clean_store
    assert_equal 0, MS.sweep_rogue_memory(@store)

    # Even with bound memory records
    MS.record(@store, topic: "Bound Topic", body: "normal memory")
    assert_equal 0, MS.sweep_rogue_memory(@store)
  end

  def test_sweep_rogue_memory_binds_unbound_raw_puts
    # Create raw put without mem.* alias
    raw_rec = @store.put(type: "memory", title: "Rogue Memory", body: "raw put content")

    # Before sweep: no ref mapping for "mem.rogue-memory"
    assert_nil @store.get(type: "memory", id: "mem.rogue-memory")

    swept_count = MS.sweep_rogue_memory(@store)
    assert_equal 1, swept_count

    # After sweep: "mem.rogue-memory" ref points to raw_rec id
    swept_rec = @store.get(type: "memory", id: "mem.rogue-memory")
    refute_nil swept_rec
    assert_equal raw_rec["id"], swept_rec["id"]

    # Subsequent record() with same topic updates the swept winner
    rec_info = MS.record(@store, topic: "Rogue Memory", body: "updated after sweep")
    assert_equal raw_rec["id"], rec_info["id"]
  end

  def test_sweep_rogue_memory_resolves_multiple_rogue_rows_by_highest_row
    # Create multiple raw puts for the same topic
    raw1 = @store.put(type: "memory", title: "Duplicated Topic", body: "first raw put")
    raw2 = @store.put(type: "memory", title: "Duplicated Topic", body: "second raw put")
    raw3 = @store.put(type: "memory", title: "Duplicated Topic", body: "third raw put (winner)")

    swept_count = MS.sweep_rogue_memory(@store)
    assert_equal 3, swept_count

    # Ref must point to winner (raw3, highest row)
    winner_rec = @store.get(type: "memory", id: "mem.duplicated-topic")
    assert_equal raw3["id"], winner_rec["id"]

    # Other rogue copies must be superseded by winner
    r1 = @store.get(type: "memory", id: raw1["id"])
    r2 = @store.get(type: "memory", id: raw2["id"])
    assert_equal V::STATUS_SUPERSEDED, r1["status"]
    assert_equal raw3["id"], r1["links"]["superseded_by"]
    assert_equal V::STATUS_SUPERSEDED, r2["status"]
    assert_equal raw3["id"], r2["links"]["superseded_by"]
  end

  # ---- 5. stub store sequence assertions --------------------------------

  class StubStore
    attr_reader :calls

    def initialize(records = {}, refs_hash = {})
      @records = records # type => { id => rec }
      @refs = refs_hash # ref => id
      @calls = []
    end

    def get(type:, id:)
      @calls << [:get, { type: type, id: id }]
      actual_id = @refs[id] || id
      @records.dig(type, actual_id)
    end

    def delete(type:, id:)
      @calls << [:delete, { type: type, id: id }]
      actual_id = @refs[id] || id
      @records[type]&.delete(actual_id)
      @refs.delete_if { |_k, v| v == actual_id }
    end

    def put(type:, title:, body: "", tags: [], links: {}, status: V::STATUS_ACTIVE, id: nil, ref: nil)
      @calls << [:put, { type: type, title: title, body: body, tags: tags, links: links, status: status, id: id, ref: ref }]
      rec_id = id || "id_#{rand(10_000)}"
      rec = { "id" => rec_id, "type" => type, "title" => title, "body" => body, "tags" => tags, "links" => links, "status" => status, "version" => 1 }
      @records[type] ||= {}
      @records[type][rec_id] = rec
      @refs[ref] = rec_id if ref
      rec
    end

    def list(type:)
      @calls << [:list, { type: type }]
      (@records[type] || {}).values.map do |r|
        Rubik::Storage::Store::Summary.new(
          id: r["id"], row: r["row"] || 1, title: r["title"], status: r["status"], updated_at: "", tags: r["tags"]
        )
      end
    end

    def refs
      @calls << [:refs, {}]
      @refs.dup
    end

    def set_ref(ref, id)
      @calls << [:set_ref, { ref: ref, id: id }]
      @refs[ref] = id
    end
  end

  def test_forget_purge_stub_store_call_sequence
    stub = StubStore.new(
      { "memory" => { "mem_123" => { "id" => "mem_123", "type" => "memory" } } },
      { "mem.topic" => "mem_123" }
    )

    res = MS.forget(stub, ref: "mem.topic", retention: "purge")
    assert res["forgot"]

    expected_sequence = [
      [:get, { type: "memory", id: "mem.topic" }],
      [:delete, { type: "memory", id: "mem_123" }]
    ]
    assert_equal expected_sequence, stub.calls
  end

  def test_forget_supersede_stub_store_call_sequence
    stub = StubStore.new(
      { "memory" => { "mem_123" => { "id" => "mem_123", "type" => "memory", "title" => "T", "body" => "B", "tags" => [], "links" => {} } } },
      { "mem.topic" => "mem_123" }
    )

    res = MS.forget(stub, ref: "mem.topic", retention: "supersede")
    assert res["forgot"]

    assert_equal :get, stub.calls[0][0]
    assert_equal :put, stub.calls[1][0]
    assert_equal V::STATUS_SUPERSEDED, stub.calls[1][1][:status]
    assert_equal "forget", stub.calls[1][1][:links]["superseded_by"]
  end

  def test_sweep_rogue_memory_stub_store_call_sequence
    stub = StubStore.new(
      {
        "memory" => {
          "m1" => { "id" => "m1", "type" => "memory", "title" => "Rogue Topic", "row" => 1, "status" => "active", "tags" => [], "links" => {} },
          "m2" => { "id" => "m2", "type" => "memory", "title" => "Rogue Topic", "row" => 2, "status" => "active", "tags" => [], "links" => {} }
        }
      },
      {}
    )

    count = MS.sweep_rogue_memory(stub)
    assert_equal 2, count

    calls_methods = stub.calls.map(&:first)
    assert_equal [:refs, :list, :set_ref, :get, :put], calls_methods
    # Verify set_ref was set to winner m2 (highest row: 2)
    set_ref_call = stub.calls.find { |c| c[0] == :set_ref }
    assert_equal "mem.rogue-topic", set_ref_call[1][:ref]
    assert_equal "m2", set_ref_call[1][:id]
    # Verify get and put (supersede) were called for duplicate m1
    get_call = stub.calls.find { |c| c[0] == :get }
    assert_equal "m1", get_call[1][:id]
    put_call = stub.calls.find { |c| c[0] == :put }
    assert_equal V::STATUS_SUPERSEDED, put_call[1][:status]
    assert_equal "m2", put_call[1][:links]["superseded_by"]
  end
end
