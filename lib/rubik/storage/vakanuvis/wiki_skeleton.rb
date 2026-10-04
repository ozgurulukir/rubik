# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Ta'rih iskeleti: wiki.home indeks sayfasını deterministik yeniden
      # hesaplar (Karpathy "compilation over retrieval" — derlenmiş sayfa
      # seti tek bakışta görünür; home kendisi bir wiki satırıdır ama
      # listeye asla girmez). Sıralama Store#list'in [type,row] sırası —
      # aynı depo ⇒ aynı home gövdesi.
      module WikiSkeleton
        module_function

        HOME_REF = "wiki.home"
        WIKI_TAGS = ["vakanuvis", "wiki"].freeze

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
          "- #{summary.title} — #{store.uri_for('wiki', summary.id)}"
        end
      end
    end
  end
end
