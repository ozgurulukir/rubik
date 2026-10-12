# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    module GoalLedger
      # Askı yaşam döngüsü (issue #106): Σ'nın suspend/resume yarısı —
      # Ledger'a include edilir (instance-method mixin; Ledger'ın private
      # yardımcılarına ve @monitor'una doğal erişim, satır cap'i disiplini).
      #
      # Suspend damgası, finalize! deseninin birebir aynısıdır: son
      # revizyon satırına satır-adresli put (id korunur, version++, gövde
      # değişmez); yalnızca storage status → "suspended" ve links'e sayaç
      # meta'sı {goal_id, steps, max_steps, extensions, tokens, reason,
      # suspended_at, attempt} (JSON dizesi — normalize_links değerleri
      # dizgeleştirir) yazılır. Askı TERMINAL DEĞİLDİR: @finalized
      # dokunulmaz, sonraki finalize! damganın üzerine yazar. Store yoksa
      # degrade sözleşmesi: tek dürüst warn, bellek-içi resume çalışır,
      # çapraz-süreç resume dürüstçe reddedilir — asla çökmez.
      module SuspendLifecycle
        # Σ çalışma gövdesinin zorunlu koleksiyonları (Ledger.seed_doc moldu).
        SIGMA_COLLECTIONS = %w[tasks findings decisions open_questions environment_notes].freeze

        # Askı damgası meta'sı (load yolunda satırdan, suspend! yolunda
        # parametreden): yukarıdaki şema; yoksa nil.
        attr_reader :suspend_meta

        def suspend!(meta)
          @monitor.synchronize do
            return nil if @finalized

            @suspend_meta = deep_dup(meta.to_h.transform_keys(&:to_s))
            if @store && @storage_id
              links = @last_links.merge("suspended" => Rubik::Platform.safe_json_generate(@suspend_meta))
              row = @store.put(type: "goal", id: @storage_id, title: row_title, body: canonical_json,
                               tags: ["goal-ledger"], links: links, status: "suspended")
              @storage_id = row["id"]
            else
              degrade_storage_once
            end
            log(:suspended, "goal ledger suspended at rev #{@doc['rev']} (attempt #{@suspend_meta['attempt']})")
            final_result
          end
        rescue StandardError => e
          degrade("suspend stamp", e)
          @monitor.synchronize { final_result }
        end

        # Damganın temizlenmesi (resume anı): satır tekrar "active" olur —
        # aksi halde koşan bir goal !goal list'te askı görünürdür. version++
        # tek maliyet; ilk kabul zaten yeni satır açar. finalize! ile aynı
        # idempotent guard; bellek-içi meta temizlenir (artık askı yok).
        def unsuspend!
          @monitor.synchronize do
            return nil if @finalized
            return nil unless @store && @storage_id

            row = @store.put(type: "goal", id: @storage_id, title: row_title, body: canonical_json,
                             tags: ["goal-ledger"], links: @last_links, status: "active")
            @storage_id = row["id"]
            @suspend_meta = nil
            log(:unsuspended, "goal ledger resume at rev #{@doc['rev']}")
            final_result
          end
        rescue StandardError => e
          degrade("unsuspend stamp", e)
          @monitor.synchronize { final_result }
        end

        # Ledger.load'un kurulum adımı: satır + JSON gövdeden çalışma
        # durumunu geri yükler — YAZMA YOKTUR. @last_links tam korunur
        # (ledger_prev zinciri ilk kabulde YENİ satıra taşınır).
        def restore_from_row!(row:, doc:)
          @monitor.synchronize do
            @doc = deep_dup(doc)
            @storage_id = row["id"]
            @last_links = deep_dup(row["links"].to_h.transform_keys(&:to_s))
            @suspend_meta = parse_suspend_meta(row)
            @rejections = 0
          end
          self
        end

        class << self
          # Çapraz-süreç resume fabrikası: askı damgası taşıyan Σ satırından
          # defteri yeniden kurar (gövde JSON'u → @doc, links → @last_links,
          # damga meta'sı → suspend_meta). YAZMA YOKTUR — load saf
          # kurulumdur; ilk kabul yeni satır açar. Dürüst red: store /
          # storage_id yok, satır yok, status "suspended" değil ya da gövde
          # bozuksa / Σ şeması eksikse nil — resume handler'ı tek cümlelik
          # ret basar. Şema red'i SAHİLENDİĞİNDE olmalı: eksik koleksiyonlu
          # bir gövde geçse resume render'da NoMethodError ile ölür, oysa
          # unsuspend! damgayı çoktan tüketmiş olurdu.
          def load(store:, storage_id:, config: nil, dmesg: nil, event_bus: nil)
            return nil unless store && storage_id

            row = store.get(type: "goal", id: storage_id.to_s)
            return nil unless row.is_a?(Hash) && row["status"] == "suspended"

            doc = JSON.parse(row["body"].to_s)
            return nil unless doc.is_a?(Hash) && doc["rev"].is_a?(Integer) &&
                             doc["objective"] && SIGMA_COLLECTIONS.all? { |key| doc[key].is_a?(Array) }

            ledger = Ledger.new(goal_text: doc["objective"].to_s,
                                max_retries: Ledger.max_patch_retries(config),
                                store: store, dmesg: dmesg, event_bus: event_bus)
            ledger.restore_from_row!(row: row, doc: doc)
            ledger
          rescue StandardError => e
            Rubik::Log.warn(:goal_ledger, "goal ledger load from suspend stamp failed " \
                                          "(#{e.class}: #{e.message}); cross-process resume refused")
            nil
          end
        end

        private

        # Satır links'indeki askı damgası meta'sını çözer (bozuk JSON →
        # nil: load dürüst devam eder, yalnız sayaç geri yüklenemez).
        def parse_suspend_meta(row)
          raw = row.dig("links", "suspended")
          parsed = JSON.parse(raw.to_s)
          parsed.is_a?(Hash) ? parsed : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
