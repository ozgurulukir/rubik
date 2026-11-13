# frozen_string_literal: true

module Rubik
  module Storage
    # BM25-lite relevance ranking (vakanuvis-v2 §4-V8, issue #408): the
    # single home of the scored-search math. Store keeps tokenization, the
    # shared @records_cache and corpus assembly; Ranking owns the candidate
    # gate, corpus statistics (total/avgdl/df), Okapi scoring, the field
    # tier bonus and the final ordering. `rank` is pure over its inputs —
    # same corpus + same tokens + same require_all ⇒ same order, every
    # replay (replay/pin contract below).
    module Ranking
      module_function

      # BM25-lite (vakanüvis-v2 §4-V8): klasik Okapi değerleri — k1 terim
      # doygunluğu, b uzunluk normalizasyonu ağırlığı.
      BM25_K1 = 1.2
      BM25_B = 0.75
      # Alan kademeli bonus (issue #99 P3): BM25 birincil kalır; başlıkta
      # geçen sorgu terimi etikette geçene, o da yalnız gövdede geçene
      # üstünlük kurar. Terim başına birimdir ve tipik idf katkısının
      # altındadır — maddesel BM25 farklarını ezmez, sadece eşit-yakın
      # skorları alan bilgisiyle kırar.
      TITLE_TIER_BONUS = 1.0
      TAGS_TIER_BONUS = 0.5

      # One public entry. Store#search_ranked supplies the corpus entries —
      # each `{records:, haystacks:, folded_fields:, has:}` where `has` is
      # the per-token include? matrix produced by the single AND/OR pass —
      # so df comes from that pass alone and tf is scanned only on matching
      # records. Ordering: score desc → updated_at desc → [type, row].
      def rank(tokens:, corpus:, require_all:)
        return [] if corpus.empty?

        total = corpus.sum { |c| c[:records].size }
        avgdl = corpus.sum { |c| c[:haystacks].sum(&:bytesize) }.fdiv(total)
        dfs = tokens.each_index.map { |ti| corpus.sum { |c| c[:has][ti].count(true) } }

        gate = ranked_gate(require_all)
        scored = corpus.flat_map do |c|
          c[:records].each_index.select { |i| gate.call(c[:has], i) }.map do |i|
            score = tokens.each_with_index.sum do |token, ti|
              df = dfs[ti]
              next 0.0 if df.zero?

              # PERF: count_occurrences using String#index avoids Array allocation of String#scan
              tf = count_occurrences(c[:haystacks][i], token)
              next 0.0 if tf.zero?

              idf = Math.log(((total - df + 0.5) / (df + 0.5)) + 1)
              dl = c[:haystacks][i].bytesize
              idf * (tf * (BM25_K1 + 1)) / (tf + (BM25_K1 * (1 - BM25_B + (BM25_B * dl / avgdl))))
            end
            # PERF: pass cached folded title and tags to avoid String folding & array join allocations per score
            f_title, f_tags = c[:folded_fields][i]
            [score + field_tier_bonus(tokens, f_title, f_tags), c[:records][i]]
          end
        end
        ordered = scored.sort do |(score_a, rec_a), (score_b, rec_b)|
          (score_b <=> score_a).nonzero? ||
            (rec_b["updated_at"].to_s <=> rec_a["updated_at"].to_s).nonzero? ||
            (rec_a["type"].to_s <=> rec_b["type"].to_s).nonzero? ||
            (rec_a["row"].to_i <=> rec_b["row"].to_i)
        end
        ordered.map { |_score, record| record }
      end

      # Aday eşiği: require_all (AND — default, recall) ya da OR
      # gevşetmesi (fallback — issue #99 P2).
      def ranked_gate(require_all)
        if require_all
          ->(has, i) { has.all? { |row| row[i] } }
        else
          ->(has, i) { has.any? { |row| row[i] } }
        end
      end

      # PERF: Zero-allocation string occurrence counting via String#index loop.
      # Replaces String#scan(token).size to avoid array allocation per matched term.
      def count_occurrences(haystack, token)
        return 0 if token.empty?

        count = 0
        offset = 0
        token_len = token.length
        while (idx = haystack.index(token, offset))
          count += 1
          offset = idx + token_len
        end
        count
      end

      # Terim başına alan izi: katlanmış başlıkta geçen terim +1.0,
      # yalnız katlanmış etiketlerde geçen +0.5, gövde izi 0 — bkz.
      # TITLE_TIER_BONUS/TAGS_TIER_BONUS. Yalnız eşik geçen kayıtlar için
      # hesaplanır (ek tarama yok); başlık/etiket önceden katlanmış
      # dizgeler olarak corpus'tan gelir (Store memoize'ı).
      def field_tier_bonus(tokens, title, tags)
        sum = 0.0
        tokens.each do |token|
          if title.include?(token)
            sum += TITLE_TIER_BONUS
          elsif tags.include?(token)
            sum += TAGS_TIER_BONUS
          end
        end
        sum
      end

      private_class_method :ranked_gate, :count_occurrences, :field_tier_bonus
    end
  end
end
