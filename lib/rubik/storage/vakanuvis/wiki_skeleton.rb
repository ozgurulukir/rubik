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

        HOME_REF = "wiki.home"
        WIKI_TAGS = ["vakanuvis", "wiki"].freeze
        SUMMARY_MAX = 120

        def rebuild_home(store)
          home = store.get(type: "wiki", id: HOME_REF)
          pages = store.list(type: "wiki").reject do |s|
            s.status == "superseded" || (home && s.id == home["id"])
          end
          body = pages.empty? ? "_(no compiled pages yet)_" : pages.map { |s| page_line(store, s) }.join("\n")
          Vakanuvis.upsert(store, type: "wiki", ref: HOME_REF,
                                  title: "Compiled knowledge (wiki home)",
                                  body: body, tags: WIKI_TAGS, links: {})
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
