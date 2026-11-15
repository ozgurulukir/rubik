# frozen_string_literal: true

require_relative "../test_helper"

# Rubik::Storage::Search — saf arama metni katmanı (issue #473): sorgu
# tokenizasyonu, samanlık kurulumu, kayıt başına katlanmış alanlar ve
# token-AND aday eşiği. Dosya sistemi / Store durumundan bağımsız.
class TestStorageSearch < Minitest::Test
  def test_tokens_fold_and_split_the_query
    assert_equal [], Rubik::Storage::Search.tokens("   ")
    assert_equal ["deploy", "quarterly"], Rubik::Storage::Search.tokens("Deploy QUARTERLY")
    # TR I-sınıfı katlaması (folding.rb sözleşmesi)
    assert_equal ["irgat"], Rubik::Storage::Search.tokens("IRGAT")
  end

  def test_haystack_of_covers_title_body_and_tags_folded
    record = { "title" => "Gateway Ops", "body" => "Handshake RETRY", "tags" => ["Ağ", "ops"] }
    haystack = Rubik::Storage::Search.haystack_of(record)
    assert_equal "gateway ops\nhandshake retry\nağ\nops", haystack
  end

  def test_folded_fields_of_pairs_title_and_tags
    record = { "title" => "Gateway Ops", "tags" => ["Ağ", "OPS"] }
    assert_equal ["gateway ops", "ağ\nops"], Rubik::Storage::Search.folded_fields_of(record)
  end

  def test_matching_indices_requires_every_token
    records = [
      { "title" => "alpha beta" },
      { "title" => "alpha only" },
      { "title" => "beta alpha gamma" }
    ]
    haystacks = records.map { |r| Rubik::Storage::Search.haystack_of(r) }
    assert_equal [0, 2], Rubik::Storage::Search.matching_indices(records, haystacks, ["alpha", "beta"])
    assert_equal [0, 1, 2], Rubik::Storage::Search.matching_indices(records, haystacks, ["alpha"])
    assert_equal [], Rubik::Storage::Search.matching_indices(records, haystacks, ["alpha", "delta"])
  end
end
