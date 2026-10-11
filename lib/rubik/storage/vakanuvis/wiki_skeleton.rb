# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Ta'rih iskeleti: wiki.home indeks sayfasını deterministik yeniden
      # hesaplar (Karpathy "compilation over retrieval" — derlenmiş sayfa
      # seti tek bakışta görünür; home kendisi bir wiki satırıdır ama
      # listeye asla girmez). Sıralama Store#list'in [type,row] sırası —
      # aynı depo ⇒ aynı home gövdesi. v2 §4-V3: her satır tek satırlık
      # ÖZET taşır (başlık+blockquote atlanır, ≤120 karakter) — LLM home'a
      # tek bakışla hangi sayfayı çekeceğine karar verir (≤2 adım erişim).
      module WikiSkeleton
        module_function

        SUMMARY_MAX = 120

        def rebuild_home(store)
          home = store.get(type: "wiki", id: Vocabulary::HOME_REF)
          pages = store.list(type: "wiki").reject do |s|
            s.status == Vocabulary::STATUS_SUPERSEDED || (home && s.id == home["id"])
          end
          body = pages.empty? ? "_(no compiled pages yet)_" : pages.map { |s| page_line(store, s) }.join("\n")
          Vakanuvis.upsert(store, type: "wiki", ref: Vocabulary::HOME_REF,
                                  title: "Compiled knowledge (wiki home)",
                                  body: body, tags: Vocabulary::WIKI_TAGS, links: {})
        end

        # Derleme dedup adayları (issue #100 P1b): aynı başlık ya da
        # birebir aynı gövdeyi taşıyan AKTİF sayfalar — süpersede
        # edilenler, home ve kendisi (excluding_id) aday değildir. Sıra
        # Store#list'in [type,row] sırası: eskisi önce, süpersede de
        # daima eskisini bastırır. Uzun gövde kıyası örneklemli değil
        # birebirdir — derleme çıktısı zaten sayfa boyutu sınırlıdır.
        def find_duplicate_pages(store, title:, body:, excluding_id: nil)
          home = store.get(type: "wiki", id: Vocabulary::HOME_REF)
          candidates = store.list(type: "wiki").reject do |s|
            s.status == Vocabulary::STATUS_SUPERSEDED ||
              (home && s.id == home["id"]) ||
              (excluding_id && s.id == excluding_id)
          end
          candidates.filter_map do |s|
            record = store.get(type: "wiki", id: s.id)
            next unless record

            record if record["title"] == title || record["body"] == body
          end
        end

        def page_line(store, summary)
          record = store.get(type: "wiki", id: summary.id)
          "- #{summary.title} — #{page_summary(record ? record['body'].to_s : '')} — #{store.uri_for('wiki', summary.id)}"
        end

        # Sayfanın açılış özeti: başlık/blok-alıntı atlanır, ilk dolu satır
        # tek satıra indirilir (AnnalWriter disiplini). Özet yoksa dürüst
        # yer tutucu — home satırı asla düşmez.
        def page_summary(body)
          line = body.lines.map(&:strip).reject(&:empty?)
                     .reject { |l| l.start_with?("#", ">") }.first.to_s
          cleaned = AnnalWriter.one_line(line, SUMMARY_MAX)
          cleaned == "(none)" ? "(no summary yet)" : cleaned
        end
      end
    end
  end
end
