# frozen_string_literal: true

require "json"

require_relative "schema"

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
        # Σ çalışma gövdesinin zorunlu koleksiyonları — şemadan TÜRETİLİR
        # (tek doğum yeri Schema.goal_skeleton; Ledger.seed_doc/snapshot da
        # aynı kaynaktan dolar. Yeni koleksiyon = tek şema düzenmesi).
        SIGMA_COLLECTIONS = Schema.goal_skeleton.sections.keys.freeze

        # Askı damgası meta'sı (load yolunda satırdan, suspend! yolunda
        # parametreden): yukarıdaki şema; yoksa nil.
        attr_reader :suspend_meta

        def suspend!(meta)
          @monitor.synchronize do
            return nil if @finalized

            @suspend_meta = deep_dup(meta.to_h.transform_keys(&:to_s))
            if @store && @storage_id
              stamp_row!(links: @last_links.merge("suspended" => Rubik::Platform.safe_json_generate(@suspend_meta)),
                         tags: ["goal-ledger"], status: "suspended")
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

            stamp_row!(links: @last_links, tags: ["goal-ledger"], status: "active")
            @suspend_meta = nil
            log(:unsuspended, "goal ledger resume at rev #{@doc['rev']}")
            final_result
          end
        rescue StandardError => e
          degrade("unsuspend stamp", e)
          @monitor.synchronize { final_result }
        end

        # Ledger.load'un kurulum adımı: satır + JSON gövdeden çalışma
        # durumunu geri yükler — YAZMA YOKTUR. @last_links zincir için
        # korunur AMA bayat "suspended" damgası düşülür: aksi halde resume
        # sonrası hiç ΔΣ kabulü olmadan gelen bir unsuspend!/finalize! ölü
        # damgayı satır links'ine geri yazar (status "active"/"failed"
        # iken links'te askı meta'sı). Taze damga suspend!'ın kendi
        # merge'ünden gelir — restore'dan değil.
        def restore_from_row!(row:, doc:)
          @monitor.synchronize do
            @doc = deep_dup(doc)
            @storage_id = row["id"]
            @last_links = deep_dup(row["links"].to_h.transform_keys(&:to_s))
            @last_links.delete("suspended")
            @suspend_meta = parse_suspend_meta(row)
            @rejections = 0
          end
          self
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
