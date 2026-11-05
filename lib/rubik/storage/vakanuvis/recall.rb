# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Deterministik geri çağırma düzlemi: sorgu → digest dizgisi. LLM'siz,
      # iş parçacığı içermeyen saf politika + üslup — Harness'in iş parçacığı
      # çekirdeğinden (kuyruk + worker + olay dağıtımı) ayrı evi. Tüm
      # RECALL_* sabitlerinin SSOT'u: Orientation ve DistillGate buradan
      # okur, Harness'e geri dokunmaz.
      module Recall
        RECALL_LIMIT = 5
        RECALL_FALLBACK_LIMIT = 3
        RECALL_BODY_SLICE = 140
        RECALL_TYPES = ["memory", "wiki"].freeze

        module_function

        # Tam deterministik, LLM'siz: Store#search_ranked BM25-lite sırası +
        # RECALL_TYPES kısıtı + ilk RECALL_LIMIT kayıt ⇒ aynı depo ⇒ aynı digest.
        # type: dizisi (v2 §4-V8) transcript/note gibi arama dışı tipleri hiç parse
        # etmez; sıralama politika kararına aittir — Store#search'in [type,row] sözleşmesi değişmez.
        def recall(store, query, types: RECALL_TYPES)
          q = query.to_s.strip
          raise ArgumentError, "recall: 'query' is required" if q.empty?

          allowed = Array(types).map(&:to_s)
          allowed = RECALL_TYPES if allowed.empty?
          hits = DistillGate.active_recall_hits(store, query: q, type: allowed).first(RECALL_LIMIT)
          unless hits.empty?
            header = "Recalled #{hits.size} entit#{hits.size == 1 ? 'y' : 'ies'} for '#{AnnalWriter.one_line(q, 80)}':"
            return "#{header}\n#{hits.map { |r| recall_line(store, r) }.join("\n")}\nRead a full record with read_file(path: '<uri above>')."
          end

          relaxed_digest(store, q, allowed)
        end

        # v2 §4-V2 + issue #99 P2: AND boşluğu tek tip körlük değil — en yakın
        # kısmi eşleşmeler dürüstçe "(fallback)" damgasıyla sunulur (gerçek
        # eşleşme değildir), transcript izleri kapsam ipucu olarak sayılır. Ne
        # fallback ne transcript izi varsa bugünkü dil/terim yönlendirmesi birebir
        # döner (keyword-AND'da en sık neden TR sorgu ↔ EN gövde uyuşmazlığıdır;
        # yanlış "hemen yeniden kaydet" yönlendirmesi burada kesilir).
        def relaxed_digest(store, query, allowed)
          q = query.to_s.strip
          # Süpersede edilmiş sayılar "en yakın kısmi eşleşme" olarak
          # sunulmaz (review M1) — emekli bir sayfayı okumaya davet etmek,
          # issue #100'ün "iki kopya, biri bozuk" bulgusunun aynısıdır.
          relaxed = DistillGate.active_recall_hits(store, query: q, type: allowed, require_all: false)
                               .first(RECALL_FALLBACK_LIMIT)
          transcripts = store.search(query: q, type: "transcript")
          if relaxed.empty? && transcripts.empty?
            return "No chronicled knowledge matches '#{AnnalWriter.one_line(q, 80)}'. Recall is keyword-AND: retry with fewer or other-language " \
                   "terms first (e.g. the TR/EN Keywords: lines). If the knowledge is genuinely missing, record it (vakanuvis action 'record') or queue a digest."
          end

          parts = []
          # Başlık + read_file ayağı yalnız gerçek fallback izi varken
          # basılır (review CR#1: "yukarıdaki uri" diyecek uri yokken
          # olmayan bir talimat modele verilmesin).
          unless relaxed.empty?
            parts << "No exact keyword-AND match for '#{AnnalWriter.one_line(q, 80)}' — closest partial matches (fallback, not true matches):"
            parts.concat(relaxed.map { |r| "- (fallback) #{recall_line(store, r)}" })
          end
          unless transcripts.empty?
            parts << "#{transcripts.size} transcript entr#{transcripts.size == 1 ? 'y' : 'ies'} mention these terms — " \
                     "the raw session logs may hold it; queue a digest to compile them."
          end
          parts << "If none of these help, retry with fewer or other-language terms (the TR/EN Keywords: lines), " \
                   "record the knowledge, or queue a digest."
          parts << "Read a full record with read_file(path: '<uri above>')." unless relaxed.empty?
          parts.join("\n")
        end

        def first_body_line(record)
          slice = record["body"].to_s.lines.map(&:strip).reject(&:empty?).first.to_s.slice(0, RECALL_BODY_SLICE)
          slice.empty? ? "(no body)" : slice
        end

        def recall_line(store, record) = "- #{record['title']} [#{record['id']}] #{first_body_line(record)} — #{store.uri_for(record['type'], record['id'])}"
      end
    end
  end
end
