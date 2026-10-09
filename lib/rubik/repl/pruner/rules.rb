# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../platform"
require_relative "../../prompt/context_compactor"

module Rubik
  module REPL
    module Pruner
      # Düzlem 1 kuralları (durumsuz, saf): pencereyi atomik birimlere
      # böler (koruma bantları + hedef sabitlemesi dahil), LLM planını
      # katı şemayla doğrular ve DOĞRULANMIŞ planı canlı pencereye
      # kopyala-doğrula-takas disipliniyle uygular. Mevcut sıkıştırma
      # koduna dokunmaz — ContextCompactor/TokenEstimator/ConversationRows
      # yalniz ÇAĞRILIR (subagent yolu bu dosyadan habersizdir).
      module Rules
        MAX_OPS = 64
        SUMMARY_MIN_CHARS = 40
        SUMMARY_MAX_CHARS = 2000
        KEEP_PREVIEW_CHARS = 400
        MIN_WINDOW_ENTRIES = 4 # trim_history_to_budget min_entries aynası
        UNIT_ID = /\Au\d+:[0-9a-f]{8}\z/

        module_function

        # Pencereyi budanabilir birim anlık görüntüsüne çevirir. Birim =
        # Prompt::ContextCompactor.group_atomic_units çıktısı (assistant+tool
        # eşleşmesi yapısal olarak korunur). Korumalı birimler (KEEP):
        # hedef sabitlemeli (<user_task> çifti), baş/bant (preserve_first_n
        # mesajını kaplayan birimler), kuyruk bandı (preserve_last_n), system
        # satırı taşıyanlar. id = "u<sıra>:<hash8>" — sıra benzersizlik,
        # hash8 bayatlık işaretidir (apply sırasında içerik kimliği).
        def build_units(window, config: {})
          groups = Prompt::ContextCompactor.group_atomic_units(Array(window))
          units = groups.map do |rows|
            { rows: rows.map { |r| Prompt::ConversationRows.row?(r) ? r.dup : r } }
          end
          units.each { |u| u[:pinned_goal?] = Prompt::ContextCompactor.unit_pins_goal?(u[:rows]) }

          protect_bands!(units, config)
          units.each_with_index do |u, idx|
            u[:id] = "u#{idx}:#{unit_digest(u[:rows])}"
            u[:tokens] = Prompt::TokenEstimator.estimate_history(u[:rows])
            u[:role] = role_label(u[:rows])
          end
          units.each(&:freeze)
          units.freeze
        end

        def unit_digest(rows)
          canonical = rows.map { |r| canonical_row(r) }
          Digest::SHA256.hexdigest(Platform.safe_json_generate(canonical))[0, 8]
        end

        # İki satır diyalektini (symbol/string anahtar) tek kanonik şekle
        # indirir — nil okumalar "" olur, anahtar sırası hash'i değiştirmez.
        def canonical_row(row)
          return { "row" => "" } unless Prompt::ConversationRows.row?(row)

          {
            "role" => Prompt::ConversationRows.role_of(row),
            "content" => Prompt::ConversationRows.content_of(row).to_s,
            "tool_call_id" => Prompt::ConversationRows.value_of(row, :tool_call_id).to_s,
            "tool_name" => Prompt::ConversationRows.value_of(row, :tool_name).to_s,
            "status" => Prompt::ConversationRows.value_of(row, :status).to_s,
            "tool_calls" => tool_calls_json(row)
          }
        end

        # LLM planını ANLIK GÖRÜNTÜYE karşı doğrular (canlı durum yok).
        # Dönüş: [plan, nil] veya [nil, insan-okur ret sebebi]. Beyaz liste
        # grameri: {"ops":[{"op":"drop","id":...},{"op":"summarize","id":...,
        # "text":...}]} — model satır/rol/talimat ENJEKTE EDEMEZ, yalnız
        # önceden doğrulanmış birimler arasından seçer ve ≤2000 karakterlik
        # özet yazar.
        def validate_plan(raw_finish_body, units)
          return [nil, "final message is empty"] if raw_finish_body.to_s.strip.empty?

          parsed = parse_json_object(raw_finish_body.to_s)
          return [nil, parsed] if parsed.is_a?(String)

          ops = parsed["ops"]
          return [nil, "'ops' must be an array"] unless ops.is_a?(Array)
          return [nil, "plan needs at least one op"] if ops.empty?
          return [nil, "plan exceeds #{MAX_OPS} ops"] if ops.size > MAX_OPS

          by_id = units.to_h { |u| [u[:id], u] }
          seen = {}
          normalized = []
          ops.each do |op|
            reason = normalize_op(op, by_id, seen, normalized)
            return [nil, reason] if reason
          end
          [{ "ops" => normalized }, nil]
        end

        # Doğrulanmış planı CANLI pencereye uygular (yalnız turn thread'i
        # çağırır). Her op'un hash'i yeniden doğrulanır: içerik değişen
        # birimler tek tek atlanır (bayat op), genel değişmezlerden biri
        # bozulursa TÜM plan düşer — giriş dizisi asla mutasyona uğramaz.
        # Dönüş: [yeni_pencere, makbuz] veya [nil, sebep].
        def apply_plan(window, plan, target_tokens:, config: {})
          return [nil, "no plan"] unless plan.is_a?(Hash) && plan["ops"].is_a?(Array)

          units = build_units(window, config: config)
          outcome = resolve_ops(plan["ops"], units)
          applied = outcome[:applied]
          return [nil, "all ops went stale (window changed since the plan)"] if applied.empty?

          candidate = assemble(units, applied)
          reason = post_invariant_reason(window, candidate, target_tokens)
          return [nil, reason] if reason

          after_tokens = Prompt::TokenEstimator.estimate_history(candidate)
          receipt = { dropped: applied.count { |_id, op| op[:kind] == :drop },
                      summarized: applied.count { |_id, op| op[:kind] == :summarize },
                      skipped_stale: outcome[:skipped_stale],
                      before_tokens: Prompt::TokenEstimator.estimate_history(window),
                      after_tokens: after_tokens }
          [candidate, receipt]
        end

        def status_report(window:, ceiling:, bits: {})
          est = Prompt::TokenEstimator.estimate_history(Array(window))
          pct = ceiling&.positive? ? " (#{(est * 100.0 / ceiling).round}% of ceiling)" : ""
          lines = ["Context pruner:",
                   "  window: #{Array(window).size} entries, ~#{est} est. tokens#{pct}",
                   "  ceiling: #{ceiling || 'unknown'}"]
          if bits.empty?
            lines << "  gate: idle"
          else
            lines << "  pruner in flight: #{bits[:in_flight] ? 'yes' : 'no'}"
            lines << "  staged plan: #{bits[:staged] ? 'waiting for the next turn boundary' : 'none'}"
            lines << "  last receipt: #{bits[:last_receipt] || 'none yet'}"
          end
          lines.join("\n")
        end

        # ---- iç kısım ---------------------------------------------------------

        # Hash döner veya ret sebebi String'i — validate_plan'ın begin/rescue
        # return dansını izole eder (Lint/NoReturnInBeginEndBlocks).
        def parse_json_object(raw)
          parsed = JSON.parse(raw)
          return "plan must be a JSON object" unless parsed.is_a?(Hash)
          return "plan must have exactly one 'ops' key" unless parsed.keys == ["ops"]

          parsed
        rescue JSON::ParserError
          "final message is not valid JSON"
        end

        # Baş/kuyruk koruma bantları apply_sliding_window ile AYNI hesapla
        # (context_compactor.rb:180-199): baş birimleri preserve_first_n
        # mesajı, kuyruk birimleri preserve_last_n mesajı kaplayana kadar;
        # system satırı ve sabitlenmiş hedef birimi her yerde korumalı.
        def protect_bands!(units, config)
          first_n = (config["preserve_first_n"] || config[:preserve_first_n] || 2).to_i
          last_n = (config["preserve_last_n"] || config[:preserve_last_n] || 6).to_i

          protected_idx = {}
          head_count = 0
          head_idx = 0
          while head_idx < units.size && head_count < first_n
            protected_idx[head_idx] = :head
            head_count += units[head_idx][:rows].size
            head_idx += 1
          end
          tail_count = 0
          tail_idx = units.size - 1
          while tail_idx >= head_idx && tail_count < last_n
            protected_idx[tail_idx] = :tail
            tail_count += units[tail_idx][:rows].size
            tail_idx -= 1
          end

          units.each_with_index do |u, idx|
            u[:protected?] = protected_idx.key?(idx) || u[:pinned_goal?] ||
                             u[:rows].any? { |r| Prompt::ConversationRows.role_of(r) == "system" }
          end
        end

        def role_label(rows)
          first = Prompt::ConversationRows.role_of(rows.first)
          rows.size > 1 ? "#{first}+tool" : first
        end

        def tool_calls_json(row)
          calls = row[:tool_calls] || row["tool_calls"]
          return "" unless calls && !calls.empty?

          Platform.safe_json_generate(calls)
        rescue StandardError
          calls.to_s
        end

        # Tek op normalize eder; ret sebebi döndürür (nil = kabul).
        def normalize_op(entry, by_id, seen, normalized)
          return "each op must be a JSON object" unless entry.is_a?(Hash)

          kind = entry["op"]
          return "unknown op '#{kind}' (valid: drop, summarize)" unless ["drop", "summarize"].include?(kind)

          expected = kind == "drop" ? ["id", "op"].freeze : ["id", "op", "text"].freeze
          return "op keys must be exactly #{expected.join(', ')}" unless entry.keys.sort == expected

          id = entry["id"]
          return "malformed unit id '#{id}'" unless id.is_a?(String) && id.match?(UNIT_ID)
          return "duplicate op for unit '#{id}'" if seen.key?(id)

          unit = by_id[id]
          return "unknown unit '#{id}'" unless unit
          return "unit '#{id}' is protected (KEEP)" if unit[:protected?]

          seen[id] = true
          clean_op = { "op" => kind, "id" => id }
          if kind == "summarize"
            text = entry["text"]
            return "summarize text must be a string" unless text.is_a?(String)

            clean = Platform.safe_utf8(text)
            return "summary must be #{SUMMARY_MIN_CHARS}-#{SUMMARY_MAX_CHARS} chars (got #{clean.length})" unless clean.length.between?(SUMMARY_MIN_CHARS, SUMMARY_MAX_CHARS)

            # Enjeksiyon kapanışı (review 2026-10-09): özet metni <user_task>
            # etiketi taşayla YENİ sabitlenmiş hedef satırı doğurabilir —
            # deterministik yığın o satırı sonsuza dek korurdu. Etiketler
            # özet içinde asla birebir yaşayamaz.
            clean = clean.gsub("<user_task>", "&lt;user_task&gt;").gsub("</user_task>", "&lt;/user_task&gt;")
            clean_op["text"] = clean
          end
          normalized << clean_op
          nil
        end

        # Op'ları canlı birimlere bağlar. Önce tam id eşleşmesi; olmazsa
        # hash8 eşleşmesi (sıra kaydırdıysa içerik hâlâ aynı olabilir).
        # Birden çok hash eşleşmesi belirsizdir → op bayat sayılır.
        def resolve_ops(ops, units)
          applied = {}
          skipped = 0
          units_by_id = units.to_h { |u| [u[:id], u] }
          ops.each do |op|
            hash8 = op["id"].split(":").last
            unit = units_by_id[op["id"]]
            unless unit && !unit[:protected?] && !applied.key?(unit[:id])
              matches = units.select do |u|
                !u[:protected?] && !applied.key?(u[:id]) && u[:id].end_with?(":#{hash8}")
              end
              unit = matches.size == 1 ? matches.first : nil
            end
            if unit.nil?
              skipped += 1
              next
            end

            applied[unit[:id]] = { kind: op["op"].to_sym, text: op["text"] }
          end
          { applied: applied, skipped_stale: skipped }
        end

        # Birimleri özgün sırasında birleştirir: düşürülenler çıkar,
        # özetlenenler tek <pruned_summary> user satırına iner (role "user"
        # — sıkı sağlayıcılar ortada system satırı reddeder; compactor
        # summary_message geleneği).
        def assemble(units, applied)
          candidate = []
          units.each do |u|
            op = applied[u[:id]]
            if op.nil?
              candidate.concat(u[:rows])
            elsif op[:kind] == :drop
              next
            else
              candidate << {
                role: "user",
                content: "<pruned_summary unit=\"#{u[:id]}\" rows=\"#{u[:rows].size}\">#{op[:text]}</pruned_summary>"
              }
            end
          end
          candidate
        end

        # Uygulama-sonu değişmezleri — biri bozulursa plan bütünüyle düşer.
        # nil = ihlal yok; String = insan-okur ihlal sebebi.
        def post_invariant_reason(original, candidate, target_tokens)
          return "pruned window would be empty" if candidate.empty?
          return "pruned window must open with a user turn (strict providers)" unless Prompt::ConversationRows.role_of(candidate.first) == "user"
          return "pruned window would be too small (< #{MIN_WINDOW_ENTRIES} entries)" if candidate.size < MIN_WINDOW_ENTRIES
          if Prompt::TokenEstimator.estimate_history(candidate) > target_tokens
            return "pruned window still over target (#{Prompt::TokenEstimator.estimate_history(candidate)} > #{target_tokens} tokens)"
          end

          # Hedef satır sayısı BİREBİR kalmalı (review 2026-10-09): yalnız
          # eksilmesi değil ARTMASI da ret — özet metninden enjekte edilen
          # sahte <user_task> satırı sonsuza dek sabitlenmiş hedef olurdu.
          original_goals = original.count { |r| Prompt::ContextCompactor.goal_message?(r) }
          candidate_goals = candidate.count { |r| Prompt::ContextCompactor.goal_message?(r) }
          return "goal-pinned message count changed (#{original_goals} -> #{candidate_goals})" if candidate_goals != original_goals

          nil
        end
      end
    end
  end
end
