# frozen_string_literal: true

require_relative "../test_helper"

# Kronikçinin kelime hazinesi (Vocabulary) — ref gramerinin (mint +
# parse), etiket dağarcığının ve status sözlüğünün TEK evi. Özellik
# testleri: her mint yolu kendi parse'ıyla geri döner ve hiçbir mint
# edilen ref Store'un tip.satır çarpışma biçimine (type_row_shaped?)
# düşmez — rakam korumasının gerçek ısırığı wiki.<digits>'tir (ilk
# segmenti Store tipi olan tek kronikçi ailesi).
class TestVakanuvisVocabulary < Minitest::Test
  V = Rubik::Storage::Vakanuvis::Vocabulary

  def test_every_minted_ref_round_trips_through_its_own_parser
    assert_equal "annal.session.test-session-42", V.session_ref("test-session-42")
    assert_equal "annal.goal.7", V.goal_ref(7)
    assert_equal "annal.goal.7", V.goal_ref("7")
    assert_equal "mem.release-checklist", V.memory_ref("Release Checklist!")
    assert_equal "wiki.release-pipeline", V.wiki_ref("release pipeline")
    assert_equal "annal.recallgap.gw-page", V.recall_gap_ref("wiki.gw-page")

    # mint ⇒ parse round-trip: slug'lı her ref kendi ayrıştırıcısını geçirir.
    assert_equal 7, V.goal_ordinal(V.goal_ref(7))
    assert V.wiki_ref?(V.wiki_ref("release pipeline"))
    assert_equal "release-pipeline", V.wiki_slug(V.wiki_ref("release pipeline"))
    assert V.memory_ref?(V.memory_ref("release checklist"))
    assert_equal "test-session-42", V.session_ref("test-session-42").split("annal.session.", 2)[1]
  end

  def test_digit_only_topics_never_mint_a_type_row_shaped_ref
    assert_equal "n42", V.slug("42")
    assert_equal "n007", V.slug("007")
    # Rakam korumasının asıl ısırığı: wiki, ilk segmenti Store tipi olan
    # tek kronikçi ailesi — "wiki.42" tip.satır çözümüne çarpışırdı.
    refute V.type_row_shaped?(V.wiki_ref("42"))
    refute V.type_row_shaped?(V.memory_ref("42"))
    refute V.type_row_shaped?(V.session_ref("42"))
    refute V.type_row_shaped?(V.goal_ref(42))
    refute V.type_row_shaped?(V.recall_gap_ref(V.wiki_ref("42")))
    # ve korumanın hedef biçimi gerçekten Store'un çarpışma şekli.
    assert V.type_row_shaped?("wiki.42")
  end

  def test_recall_gap_ref_rejects_a_non_wiki_page_ref
    assert_raises(ArgumentError) { V.recall_gap_ref("mem.some-card") }
    assert_raises(ArgumentError) { V.recall_gap_ref("annal.session.x") }
    assert_raises(ArgumentError) { V.recall_gap_ref("not-a-ref") }
    assert_nil V.wiki_slug("mem.some-card"), "wiki_slug answers nil for a non-wiki ref"
  end

  def test_id_type_answers_the_type_of_store_minted_ids_and_nil_for_junk
    assert_equal "plan", V.id_type("plan.3.9f86d081884c7d21")
    assert_equal "wiki", V.id_type("wiki.41.0123456789abcdef")
    assert_nil V.id_type("wiki.release-pipeline"), "a ref is not an id — no type answer"
    assert_nil V.id_type("plan.3.short")
    assert_nil V.id_type("3.9f86d081884c7d21")
    assert_nil V.id_type("junk")
    assert_nil V.id_type(nil)
  end

  def test_tag_vocabularies_carry_the_base_tag_and_stay_frozen
    [V::ANNAL_TAGS, V::MEMORY_TAGS, V::WIKI_TAGS].each do |tags|
      assert tags.frozen?, "tag vocabularies are frozen"
      assert_includes tags, V::BASE_TAG
    end
    assert_equal ["vakanuvis", "annal"], V::ANNAL_TAGS
    assert_equal ["vakanuvis", "memory"], V::MEMORY_TAGS
    assert_equal ["vakanuvis", "wiki"], V::WIKI_TAGS
    assert_equal "goal", V::GOAL_TAG
    assert_equal "recall-gap", V::GAP_TAG
    assert_equal "wiki.home", V::HOME_REF
  end

  def test_status_lexicon_is_the_single_spelling_home
    assert_equal "active", V::STATUS_ACTIVE
    assert_equal "superseded", V::STATUS_SUPERSEDED
    assert_equal "completed", V::TRANSCRIPT_COMPLETED
    # Depolama düzleminin kronikçi sözlüğüyle okunan status değerleri
    # aynı hecelemeden gelir (tek yazım evi).
    assert_equal V::STATUS_SUPERSEDED, "superseded"
  end
end
