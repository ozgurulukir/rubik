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

        # Deterministik Keywords onarımı (issue #99 P1): Keywords: satırı
        # olmayan kart sessizce gömülür — hata yazım anında, bedava olan
        # yerde yakalanır. Ret red değil onarımdır: gövdeye katlama-
        # tokenize'dan çıkan en sık terimler eklenir. Onarım upsert'ten
        # ÖNCE uygulanır: replay skip'i (content_unchanged?) onarılmış
        # gövdeyi kıyaslar, idempotency bozulmaz.
        KEYWORDS_LINE = /\Akeywords?:/i
        KEYWORDS_MAX = 6
        MIN_TERM_LENGTH = 3
        # Katlanmış (Folding.fold) ve [a-z0-9]+ tokenize uzayında durur.
        # DİAKRİKTİLİ TR sözcükler (ç/ğ/ö/ş/ü) tokenize'da parçalanır ve
        # ≥3'lük parçalar süzülebilir (review CR#6: "kütüphane"→"phane"
        # sınıfı) — onarım kalite hedefidir, recall doğruluğunu etkilemez:
        # gövde metni zaten arama samanlığının parçasıdır. Ciddi TR kartlar
        # için gerçek güvence eliciden yazılan Keywords: satırıdır.
        STOPWORDS = [
          "the", "and", "for", "are", "but", "not", "you", "your", "with", "from", "this", "that",
          "have", "has", "had", "was", "were", "will", "would", "can", "could", "should", "into",
          "onto", "over", "under", "then", "than", "when", "what", "which", "while", "where", "why",
          "how", "all", "any", "some", "such", "only", "just", "also", "very", "more", "most",
          "per", "via", "its", "does", "did", "done", "been", "being", "same", "other", "because",
          "however", "without", "again", "both", "each", "between", "through", "during", "before",
          "after", "above", "below", "out", "off", "use", "used", "uses", "using", "new", "old",
          "get", "got", "set", "one", "two", "three", "first", "second", "third", "next", "last",
          "may", "might", "must", "shall",
          "ve", "ile", "ama", "fakat", "eger", "ancak", "daha", "bir", "bu", "su", "ne", "gibi",
          "kadar", "sonra", "once", "var", "yok", "degil", "olan", "olur", "oldu", "ise", "cok",
          "az", "hem", "ya", "nasil", "neden"
        ].freeze

        # Maestro talebiyle memory kartı (K7: authorship maestro'nun,
        # yazma disiplini Düzlem 1'in). ref = mem.<slug(topic)>; aynı
        # konuya ikinci record aynı satırı günceller (version ancak içerik
        # değişince artar). tags (issue #99 P1): kullanıcı etiketleri
        # Vocabulary ile birleşir — recall haystack'i etiketleri de tarar.
        def record(store, topic:, body:, links: {}, tags: [])
          clean_topic = topic.to_s.strip
          raise ArgumentError, "record: 'topic' is required" if clean_topic.empty?
          raise ArgumentError, "record: 'body' is required" if body.to_s.strip.empty?

          user_tags = validate_tags(tags)
          repaired, state = ensure_keywords(body.to_s, title: clean_topic)
          ref = Vocabulary.memory_ref(clean_topic)
          rec = Vakanuvis.upsert(store, type: "memory", ref: ref,
                                        title: AnnalWriter.one_line(clean_topic, 120),
                                        body: repaired,
                                        tags: (Vocabulary::MEMORY_TAGS + user_tags).uniq,
                                        links: links)
          { "ref" => ref, "id" => rec["id"], "version" => rec["version"], "skipped" => rec["skipped"],
            "keywords_extracted" => state == :extracted, "keywords_state" => state.to_s }
        end

        # issue #100 P1'in ret ailesi: kullanıcı etiketleri dizgi olmalı —
        # boolean/sayı burada, record kapısında kesilir (Store#put'tan önce).
        def validate_tags(tags)
          list = Array(tags)
          list.each do |tag|
            next if tag.is_a?(String)

            raise ArgumentError,
                  "record tags must be strings — got #{tag.class} (#{tag.inspect}). " \
                  "Pass an array of strings."
          end
          list
        end

        # Gövde Keywords: satırı taşıyor mu (case-insensitive)? Taşımıyorsa
        # deterministik terimlerden bir tane ekler. Dönüş: [gövde, durum] —
        # durum :present (satır vardı), :extracted (eklendi) ya da :none
        # (satır yok VE terim çıkmadı — review M4: bu düşüş sessiz
        # kalmaz, makbuz "none" taşır ve kart yüzü uyarır).
        def ensure_keywords(body, title: "")
          return [body, :present] if body.lines.any? { |line| line.match?(KEYWORDS_LINE) }

          terms = extract_terms("#{title}\n#{body}")
          return [body, :none] if terms.empty?

          ["#{body.rstrip}\n\nKeywords: #{terms.join('; ')}", :extracted]
        end

        # Deterministik terim çıkarımı: katlama üzerinden tokenize,
        # stopwords ve kısa öbekler dışarı, sıra [-sıklık, ilk geçme yeri] —
        # aynı gövde her zaman aynı satırı üretir.
        def extract_terms(text)
          tokens = Folding.fold(text).scan(/[a-z0-9]+/).reject do |token|
            token.size < MIN_TERM_LENGTH || STOPWORDS.include?(token)
          end
          counts = Hash.new(0)
          first_seen = {}
          tokens.each_with_index do |token, index|
            counts[token] += 1
            first_seen[token] = index unless first_seen.key?(token)
          end
          counts.keys.sort_by { |token| [-counts[token], first_seen[token]] }.first(KEYWORDS_MAX)
        end

        # K2: retention=supersede (default) iz bırakır — status + halef
        # link'i; retention=purge satırı sert siler (refs de düşer).
        # Not refs'i de çözümlenir (issue #100 follow-up: notlerin yaşam
        # döngüsü — "note yalnız birikir" gözlemi): önce memory, yoksa
        # note; stub dizisi memory yolunda değişmez.
        def forget(store, ref:, retention: "supersede")
          type = "memory"
          rec = store.get(type: type, id: ref)
          if rec.nil?
            type = "note"
            rec = store.get(type: type, id: ref)
          end
          return { "ref" => ref.to_s, "forgot" => false } unless rec

          if retention.to_s == "purge"
            deleted = store.delete(type: type, id: rec["id"])
            return { "ref" => ref.to_s, "forgot" => false } unless deleted

            { "ref" => ref.to_s, "id" => rec["id"], "forgot" => true, "mode" => "purge", "type" => type }
          else
            Vakanuvis.supersede_record(store, rec, by: "forget")
            { "ref" => ref.to_s, "id" => rec["id"], "forgot" => true, "mode" => "supersede", "type" => type }
          end
        end

        # K9 süpürme: hiçbir mem.* alias'ına bağlı olmayan (yani ham
        # `storage put type=memory` ile açılmış) satırları disipline
        # sokar — başlıktan slug türet, en yeni satıra mem.<slug> ref'i
        # bağla (bir sonraki record() artık O satırı günceller), aynı
        # slug'a düşen eski kopyaları supersede et. Mevcut canonical ref
        # her zaman korunur; kaçak kopyalar onun lehine emekli edilir. Deterministik: sıra
        # ve seçim yalnızca [row] üzerinden.
        def sweep_rogue_memory(store)
          bindings = store.refs.select { |ref, _id| Vocabulary.memory_ref?(ref) }
          bound_ids = bindings.values
          rows = store.list(type: "memory").reject do |s|
            bound_ids.include?(s.id) || s.status == Vocabulary::STATUS_SUPERSEDED
          end
          return 0 if rows.empty?

          swept = 0
          rows.group_by { |s| Vocabulary.slug(s.title) }.each do |slug, group|
            ref = Vocabulary.memory_ref(slug)
            winner_id = bindings[ref]
            unless winner_id
              winner_id = group.max_by(&:row).id
              store.set_ref(ref, winner_id)
            end
            group.reject { |s| s.id == winner_id }.each do |s|
              rogue = store.get(type: "memory", id: s.id)
              Vakanuvis.supersede_record(store, rogue, by: winner_id) if rogue
            end
            swept += group.size
          end
          swept
        end
      end
    end
  end
end
