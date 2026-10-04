# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Vakayiname: ham annal yazarı (Düzlem 1, deterministik). Olay
      # özeti SATIRLARI üretir ve ref-bazlı upsert ile note tipine ekler.
      # Gövdede duvar saati YOK — aynı olay dizisi aynı gövdeyi üretir
      # (content hash sabit kalır, replay'de put atlanır). Her satırın
      # sonundaki `(event=<anahtar>)` hem okunabilir hem yeniden teslim
      # tekilleştirme (dedup) anahtarıdır.
      module AnnalWriter
        module_function

        ANNAL_TAGS = ["vakanuvis", "annal"].freeze

        def session_ref(slug) = "annal.session.#{slug}"
        def goal_ref(ordinal) = "annal.goal.#{ordinal}"

        def session_title(slug) = "Vakanüvis session annal — #{slug}"

        def goal_title(ordinal, goal_text) = "Goal ##{ordinal} — #{one_line(goal_text, 60)}"

        # Subagent tamamlanma satırı. storage_id yoksa (eski yayıncılar /
        # test ikizleri) konuşma id'sine düşer — transcript ref'i o anlık
        # çözümlenemez, olay yine de kaydedilir.
        def subagent_line(seq, payload)
          sid = payload[:storage_id].to_s
          sid = payload[:id].to_s if sid.empty?
          role = one_line(payload[:role], 40)
          state = payload[:state].to_s
          "- [#{seq}] subagent #{sid} role=#{role} state=#{state} (event=subagent.#{sid}.#{state})"
        end

        # Goal bitiş satırı (+ annal başlık satırı olarak goal metni).
        def goal_lines(seq, payload)
          state = payload[:status].to_s
          head = "- [#{seq}] goal status=#{state} steps=#{payload[:steps]}/#{payload[:max_steps]}"
          head += " error=#{one_line(payload[:last_error], 80)}" unless payload[:last_error].to_s.empty?
          [["goal.#{payload[:goal_ordinal]}.#{state}", "#{head} (event=goal.#{payload[:goal_ordinal]}.#{state})"]]
        end

        def goal_header_line(goal_text)
          text = one_line(goal_text, 200)
          "goal: #{text}"
        end

        # Satır ekleme + tekilleştirme: body'de anahtarı olan satır bir
        # daha yazılmaz (olay yeniden teslimi — resume sonrası ikinci
        # tamamlanma gibi — yinelenen satır açmaz).
        def append(store, ref:, title:, tags: ANNAL_TAGS, links: {}, lines: [])
          existing = store.get(type: "note", id: ref)
          body = existing ? existing["body"].to_s : ""
          fresh = lines.reject { |key, _line| body.include?("(event=#{key})") }
          return existing if existing && fresh.empty?

          merged = ([body] + fresh.map { |_key, line| line }).reject { |l| l.to_s.strip.empty? }.join("\n")
          Vakanuvis.upsert(store, type: "note", ref: ref, title: title, body: merged,
                                  tags: tags, links: links, status: "active")
        end

        # Çok satırlı/borulu metni tek satıra indirger (annal satırları
        # asla satır kırmasın — dedup anahtarı satır sonunda taşınır).
        def one_line(text, limit)
          clean = text.to_s.tr("\n", " ").tr("|", "/").strip
          return "(none)" if clean.empty?

          clean.size <= limit ? clean : "#{clean[0, limit]}…"
        end
      end
    end
  end
end
