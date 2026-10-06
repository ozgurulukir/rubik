# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Mühimme küratörlüğü: memory kartlarının yazma disiplini (record),
      # emeklilik politikası (forget — K2 supersede/purge) ve kaçak ham
      # storage put'ların süpürülmesi (K9 tek-yol disiplininin son savunma
      # hattı). Yazmaların hepsi Vakanuvis.upsert'ten geçer: ref minting,
      # get-then-put ve hash-değişmediyse-skip bedava gelir.
      module MemorySteward
        module_function

        MEMORY_TAGS = ["vakanuvis", "memory"].freeze

        # Maestro talebiyle memory kartı (K7: authorship maestro'nun,
        # yazma disiplini Düzlem 1'in). ref = mem.<slug(topic)>; aynı
        # konuya ikinci record aynı satırı günceller (version ancak içerik
        # değişince artar).
        def record(store, topic:, body:, links: {})
          clean_topic = topic.to_s.strip
          raise ArgumentError, "record: 'topic' is required" if clean_topic.empty?
          raise ArgumentError, "record: 'body' is required" if body.to_s.strip.empty?

          ref = "mem.#{Vakanuvis.slugify(clean_topic)}"
          rec = Vakanuvis.upsert(store, type: "memory", ref: ref,
                                        title: AnnalWriter.one_line(clean_topic, 120),
                                        body: body.to_s, tags: MEMORY_TAGS, links: links)
          { "ref" => ref, "id" => rec["id"], "version" => rec["version"], "skipped" => rec["skipped"] }
        end

        # K2: retention=supersede (default) iz bırakır — status + halef
        # link'i; retention=purge satırı sert siler (refs de düşer).
        def forget(store, ref:, retention: "supersede")
          rec = store.get(type: "memory", id: ref)
          return { "ref" => ref.to_s, "forgot" => false } unless rec

          if retention.to_s == "purge"
            store.delete(type: "memory", id: rec["id"])
            { "ref" => ref.to_s, "id" => rec["id"], "forgot" => true, "mode" => "purge" }
          else
            Vakanuvis.supersede_record(store, rec, by: "forget")
            { "ref" => ref.to_s, "id" => rec["id"], "forgot" => true, "mode" => "supersede" }
          end
        end

        # K9 süpürme: hiçbir mem.* alias'ına bağlı olmayan (yani ham
        # `storage put type=memory` ile açılmış) satırları disipline
        # sokar — başlıktan slug türet, en yeni satıra mem.<slug> ref'i
        # bağla (bir sonraki record() artık O satırı günceller), aynı
        # slug'a düşen eski kopyaları supersede et. Deterministik: sıra
        # ve seçim yalnızca [row] üzerinden.
        def sweep_rogue_memory(store)
          bound_ids = store.refs.select { |ref, _id| ref.start_with?("mem.") }.values
          rows = store.list(type: "memory").reject do |s|
            bound_ids.include?(s.id) || s.status == "superseded"
          end
          return 0 if rows.empty?

          swept = 0
          rows.group_by { |s| Vakanuvis.slugify(s.title) }.each do |slug, group|
            winner = group.max_by(&:row)
            store.set_ref("mem.#{slug}", winner.id)
            group.reject { |s| s.id == winner.id }.each do |s|
              rogue = store.get(type: "memory", id: s.id)
              Vakanuvis.supersede_record(store, rogue, by: winner.id) if rogue
            end
            swept += group.size
          end
          swept
        end
      end
    end
  end
end
