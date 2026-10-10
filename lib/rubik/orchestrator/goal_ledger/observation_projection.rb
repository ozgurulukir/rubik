# frozen_string_literal: true

require_relative "../../prompt/conversation_rows"

module Rubik
  module Orchestrator
    module GoalLedger
      # Gözlem projeksiyonu (goal-ledger planı D): goal-loop observation'larının
      # Σ üzerinden erken yapısal projeksiyonu — compaction'ın TIER 0'ı.
      #
      # Sözleşmeler: (1) yalnız goal-mode user kanalı (directive_for önkoşul
      # matrisi: goal_mode? → knob'lar → coeffect → rev ≥ 1; herhangi biri
      # yoksa nil → compaction byte-özdeş); (2) satır DÜŞÜRME YOK — yalnız
      # content tombstone'u (tool_call_id pairing'i korunur, orphan-id 400
      # riski yapısal olarak imkânsız); (3) kayıt katmanı dokunulmaz —
      # tombstone yalnız compact_history'nin dup kopyasına yazılır
      # ("prompt'tan atmak ≠ kayıttan atmak"); (4) worker thread yok —
      # directive çözümü + uygulama yalnız turn thread'indedir.
      module ObservationProjection
        MODULE_NAME = "update_goal_ledger" # GoalLedger::TOOL_NAME SSOT ile aynı değer
        SKILL_TOOL_NAME = "skill"          # progressive disclosure payload muafiyeti

        module_function

        # Önkoşul matrisi -> Directive | nil. Misconfiguration dürüstlüğü:
        # observe_projection ON ama enabled OFF iken tek dmesg warn (çağrı
        # yeri compaction'tır — doğal oran-limitli).
        def directive_for(deps:)
          config = deps.config
          # goal_mode? yüklü olmayan test double'ları (ShellDeps method_missing
          # raise eder) yapısal olarak dışla — non-goal muamelesi görsünler.
          return nil unless deps.respond_to?(:goal_mode?) && deps.goal_mode?

          enabled = Ledger.enabled?(config)
          unless enabled
            if config_get(config, "goal.ledger.observe_projection", true) && deps.respond_to?(:runtime_manager)
              dmesg = Rubik::Coeffects.get(deps.runtime_manager&.context, Rubik::Coeffects::DMESG)
              if dmesg.respond_to?(:log)
                dmesg.log(:orchestrator, :warn,
                          "goal.ledger.observe_projection is ON but goal.ledger.enabled is OFF — observation projection inert")
              end
            end
            return nil
          end
          return nil unless config_get(config, "goal.ledger.observe_projection", true)

          ledger = Rubik::Coeffects.get(deps.runtime_manager&.context, Rubik::Coeffects::GOAL_LEDGER)
          return nil unless ledger.respond_to?(:rev)
          return nil unless ledger.rev.is_a?(Integer) && ledger.rev >= 1

          window = config_get(config, "goal.ledger.observe_window", 5).to_i
          Directive.new(ledger: ledger, window: [window, 1].max, deps: deps)
        end

        def config_get(config, key, default)
          return default if config.nil?

          val = if config.is_a?(Hash)
                  config.dig(*key.to_s.split("."))
                elsif config.respond_to?(:fetch)
                  config.fetch(key, nil)
                end
          val.nil? ? default : val
        end
      end

      # Kural: anchor = en yeni KABUL edilmiş update_goal_ledger tool satırını
      # içeren atomic unit (model o çağrıyı yaparken önceki tüm observation'ları
      # görmüştü). Anchor'dan önceki birimler = banked; son K assistant-taşıyan
      # birim + anchor + sonrası daima raw. Banked bölgedeki tool satırlarının
      # content'i tombstone ile değişir; diğer anahtarlar bit-bit korunur.
      class ObservationProjection::Directive
        def initialize(ledger:, window:, deps:)
          @ledger = ledger
          @window = window
          @deps = deps
        end

        attr_reader :rev

        # -> {count:, rev:, reclaimed_tokens:} (rows KOPYASI üzerinde çalışır)
        def apply!(rows)
          before = Prompt::TokenEstimator.estimate_history(rows)
          units = Prompt::ContextCompactor.group_atomic_units(rows)
          anchor_idx = anchor_unit_index(units)
          count = 0
          rev_now = @ledger.rev
          units.each_with_index do |unit, idx|
            next unless banked?(idx, anchor_idx, units)
            next if Prompt::ContextCompactor.unit_pins_goal?(unit) # <user_task> taşıyan birim asla emilmez

            unit.each do |row|
              count += 1 if tombstone!(row, rev_now)
            end
          end
          return { count: 0, rev: rev_now, reclaimed_tokens: 0 } if count.zero?

          reclaimed = before - Prompt::TokenEstimator.estimate_history(rows)
          observe(count, rev_now, reclaimed)
          { count: count, rev: rev_now, reclaimed_tokens: reclaimed }
        end

        private

        # En yeni accepted anchor biriminin index'i; hiç yoksa nil → no-op
        # (anchor'sız banked bölge tanımsızdır — dürüst iç çekim yapmayız).
        def anchor_unit_index(units)
          units.rindex { |unit| unit.any? { |row| anchor_row?(row) } }
        end

        def anchor_row?(row)
          return false unless Prompt::ConversationRows.row?(row)

          Prompt::ConversationRows.role_of(row) == "tool" &&
            tool_name_of(row) == ObservationProjection::MODULE_NAME &&
            row[:status].to_s != "error" && row["status"].to_s != "error"
        end

        # Recency: son K assistant-taşıyan birimin İLKİnden itibaren her şey
        # (ve anchor'u ve sonrası) raw kalır; banked = idx < anchor VE
        # idx < recency_start.
        def banked?(idx, anchor_idx, units)
          return false if anchor_idx.nil? || idx >= anchor_idx

          assistant_units = units.each_index.select { |i| units[i].any? { |r| assistant_row?(r) } }
          recency_start = assistant_units[[assistant_units.size - @window, 0].max] || units.size
          idx < recency_start
        end

        def assistant_row?(row)
          Prompt::ConversationRows.row?(row) && Prompt::ConversationRows.role_of(row) == "assistant"
        end

        # Muafiyetler: ledger tool satırları (Σ denetim izi), skill gövdeleri,
        # goal-pinned birimler, user/assistant/system satırları (kural gereği
        # zaten aday değil), hâlihazırda tombstone taşıyanlar (idempotence).
        def tombstone!(row, rev_now)
          return false unless Prompt::ConversationRows.row?(row)

          role = Prompt::ConversationRows.role_of(row)
          return false unless ["tool", "tool_result"].include?(role)

          name = tool_name_of(row)
          return false if name == ObservationProjection::MODULE_NAME
          return false if name == ObservationProjection::SKILL_TOOL_NAME
          return false if row[:status].to_s == "error" || row["status"].to_s == "error"

          key = Prompt::ConversationRows.content_key_of(row)
          content = row[key].to_s
          return false if content.start_with?("<absorbed_into_ledger")

          row[key] = %(<absorbed_into_ledger rev="#{rev_now}" tool="#{Rubik::Platform.xml_escape(name.to_s)}" />)
          true
        end

        def tool_name_of(row)
          (row[:tool_name] || row["tool_name"]).to_s
        end

        # Sessizlik sözleşmesi: tek gözlemlenebilirlik on_step
        # (:ledger_absorb_drop — StepFormatter bilinmeyen tipte nil döner →
        # UI sessiz) + dmesg ring kaydı. Notice/event_bus/wake YOK.
        def observe(count, rev_now, reclaimed)
          @deps.on_step&.call(type: :ledger_absorb_drop, count: count, rev: rev_now,
                              reclaimed_tokens: reclaimed,
                              step: @deps.respond_to?(:step_count) ? @deps.step_count : nil,
                              max_steps: @deps.respond_to?(:max_steps) ? @deps.max_steps : nil)
          dmesg = Rubik::Coeffects.get(@deps.runtime_manager&.context, Rubik::Coeffects::DMESG)
          if dmesg.respond_to?(:log)
            dmesg.log(:orchestrator, :info,
                      "goal ledger absorbed #{count} observation row(s) (rev=#{rev_now}, ~#{reclaimed} tokens reclaimed)")
          end
        rescue StandardError => e
          Rubik::Log.warn(:orchestrator, "observation projection observability failed (#{e.class}: #{e.message})")
        end
      end
    end
  end
end
