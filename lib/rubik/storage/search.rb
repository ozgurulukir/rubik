# frozen_string_literal: true

require_relative "folding"

module Rubik
  module Storage
    # The single home of the search scoring pipeline's pure text layer
    # (issue #473): tokenization, haystack construction, per-record folded
    # fields and the token-AND candidate gate. Every function here is pure
    # over its inputs — no I/O, no cache, no Store state — so the scoring
    # path is unit-testable without the filesystem. Store keeps persistence,
    # the shared @records_cache memoization and corpus assembly; Ranking
    # owns the BM25-lite math; Search owns everything that feeds it.
    module Search
      module_function

      # Sorgu katlaması + tokenizasyonu (Folding.fold — TR I-sınıfı dahil
      # tek katlama kuralı, folding.rb). Token-AND semantiğinin girdisi:
      # her boşlukla ayrılmış terim, kaydın samanlığında geçmeli. Tek
      # substring araması "ratelimit-lock regression 11/11" gibi doğal çok
      # kelimeli sorguları 0 sonuçla bıraktığı için terimlere bölünür
      # (js-tangram olay raporu 2026-10-04, olay #2); tek terimli sorgular
      # eski davranışın birebir aynısı.
      def tokens(query)
        Folding.fold(query).split
      end

      # Arama samanlığı: title+body+tags, tek katlama. Kayıt kümesi
      # paylaşımlı/frozen olduğundan sonuç da mutasyona kapalıdır
      # (include?/scan/bytesize mutasyon yapmaz).
      def haystack_of(record)
        Folding.fold("#{record['title']}\n#{record['body']}\n#{Array(record['tags']).join("\n")}")
      end

      # Sıralama katmanı için kayıt başına katlanmış [başlık, etiket] çifti
      # (Ranking#field_tier_bonus'un alan kademeli bonus girdisi).
      def folded_fields_of(record)
        [Folding.fold(record["title"]), Folding.fold(Array(record["tags"]).join("\n"))]
      end

      # Token-AND aday üretimi: her terim kaydın samanlığında geçmeli.
      # Kayıt ve samanlık dizileri aynı sırada (each_index hizalı) olmalıdır;
      # eşleşen kayıtların indekslerini döndürür.
      def matching_indices(records, haystacks, tokens)
        records.each_index.select { |i| tokens.all? { |token| haystacks[i].include?(token) } }
      end
    end
  end
end
