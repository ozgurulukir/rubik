# frozen_string_literal: true

module Rubik
  module REPL
    module Pruner
      # Düzlem 1'in durumlu yarısı (DistillGate::Gate geleneği): doğum
      # sicili, aşamalı plan yuvası ve oran/oran-limit sayaçları. ctx
      # servisi DEĞİLDİR, kendi thread'i YOKTUR (worker Harness'te kalır);
      # ömrü sahibi Harness'in ömrüdür. Tek @lock sicil + aşamalı yuva +
      # sayaçları SAHİPLENİR; kilit altında yalnız supervisor.spawn çağrısı
      # vardır (vakanüvis tekyönlü kilit düzeni) — shell'e asla geri
      # dokunulmaz, pencere mutasyonu yalnız turn thread'inde yaşar.
      class Gate
        attr_reader :supervisor, :dmesg, :max_steps, :model

        def initialize(shell:, ceiling_resolver:, config: nil, supervisor: nil, dmesg: nil, event_bus: nil)
          @shell = shell
          @config = config
          @supervisor = supervisor
          @dmesg = dmesg
          @event_bus = event_bus
          @ceiling_resolver = ceiling_resolver
          @trigger_ratio = fetch_cfg("subagents.pruner.trigger_ratio", 0.6).to_f
          @target_ratio = fetch_cfg("subagents.pruner.target_ratio", 0.35).to_f
          @max_steps = fetch_cfg("subagents.pruner.max_steps", 16).to_i
          @model = fetch_cfg("subagents.pruner.model", nil)
          @min_turns_between = fetch_cfg("subagents.pruner.min_turns_between", 5).to_i
          # Koruma bantları context.* SSOT'sundan — anlık görüntü VE canlı
          # uygulama AYNI bantla çalışır (farklı bant = "her op bayat" yanılsaması).
          @bands = {
            "preserve_first_n" => fetch_cfg("context.preserve_first_n", 2).to_i,
            "preserve_last_n" => fetch_cfg("context.preserve_last_n", 6).to_i
          }.freeze
          @lock = Mutex.new
          @pruners = {}              # inst_id -> iş zarfı (anlık görüntü)
          @staged = nil              # doğrulanmış plan, turn sınırını bekler
          # Oran-limit: boot'ta SİLAHLI başlar (geri yüklenen oturumun büyük
          # penceresi ilk turn'de budanabilsin); note_turn! her kök-turn'de
          # artırır, başarılı uygulama VE her başarısız/ret sonucunda sıfırl
          # (ret sonrası sıfır, ardışık doğum döngüsünü min_turns_between
          # turn boyunca geri çeker — sessiz maliyet döngüsü yok).
          @turns_since_prune = @min_turns_between
          @last_receipt = nil
        end

        # ---- Seam 0: kworker (:turn_finished aboneliği) --------------------

        # Her kök-turn sonunda bir kez çağrılır (abonelik bloğu): oran-limit
        # sayacı TURNU sayar, denemeyi değil — kapalı/ıskalanan turn'lar da
        # sayaca yazılır ki "min turn bekle" sözü gerçek turn cinsinden olsun.
        def note_turn!
          @lock.synchronize { @turns_since_prune += 1 }
        end

        # ---- Seam 1: araç/!prune + kworker (:turn_finished) ----------------

        # Pencereyi iş zarfına çevirir (Rules.build_units anlık görüntüsü
        # ÇAĞIRAN yerde; kworker okuması turn thread'iyle yarışabilir —
        # apply'daki hash8 yeniden doğrulaması yarışmayı "bayat op"a
        # indirger, veri bozulmaz). forced=true (araç/komut) oran + oran-
        # limit atlar. Dönüş: [zarf, nil] veya [nil, sembol_sebep]
        # (:busy/:staged/:rate_limited/:under_ratio/:no_ceiling).
        def stage_job(window, reason:, forced:)
          ceiling = resolve_ceiling
          return [nil, :no_ceiling] if ceiling.nil? || !ceiling.positive?

          skip = nil
          @lock.synchronize do
            skip = :busy if @pruners.any?
            skip ||= :staged if @staged
            skip = :rate_limited if !forced && skip.nil? && (@turns_since_prune < @min_turns_between)
          end
          return [nil, skip] if skip

          est = Prompt::TokenEstimator.estimate_history(Array(window))
          return [nil, :under_ratio] if !forced && est < (ceiling * @trigger_ratio).to_i

          units = Rules.build_units(window, config: @bands)
          envelope = { units: units, ceiling: ceiling,
                       target_tokens: (ceiling * @target_ratio).to_i,
                       est_tokens: est, trigger_ratio: @trigger_ratio,
                       brief_budget_chars: Brief.budget_chars_for(ceiling),
                       reason: reason.to_s, forced: forced }
          claimed = @lock.synchronize do
            next false if @pruners.any? || @staged

            @pruners[:__pending__] = envelope # yer tutucu: iş kuyrukta
            true
          end
          return [nil, :busy] unless claimed

          [envelope, nil]
        end

        # ---- Seam 2: worker thread'i (Harness :job olayını işlerken) ------

        # Zarfı LLM budayıcısına doğurur (claim→spawn→confirm tek @lock
        # penceresinde — DistillGate koreografisi). Brif zarfın içindedir
        # (Harness kurar — brifsiz iş doğmaz); doğum başarısızsa uçuş düşer,
        # otomatik yol kendini bir sonraki kapıda yeniden dener.
        def spawn_job(envelope)
          allowed = envelope[:brief] ? spawn_allowed_reason : :no_brief
          @lock.synchronize do
            unless allowed == true
              @pruners.delete(:__pending__)
              back_off!
              Pruner.log_via(@dmesg, :warn, "pruner spawn skipped (#{allowed}) — window untouched")
              next false
            end
            begin
              inst = @supervisor.spawn(
                role: Harness::PRUNER_ROLE, prompt: envelope[:brief],
                type_name: Harness::TYPE_NAME,
                max_steps: @max_steps, model: @model || "inherit"
              )
              @pruners.delete(:__pending__)
              @pruners[inst.id.to_s] = envelope
              Pruner.log_via(@dmesg, :info, "pruner spawned (#{envelope[:reason]}) — plan will be validated and staged")
              true
            rescue StandardError => e
              @pruners.delete(:__pending__)
              back_off!
              Pruner.log_via(@dmesg, :warn, "pruner spawn failed (#{envelope[:reason]}): #{e.class}: #{e.message}")
              false
            end
          end
        end

        # Brif üst sınırdan büyükse ya da iş kuyruk taşmasıyla düşürülürse
        # uçuş yer tutucusunu temizler (worker çağırır) — kapı asla takılı
        # kalmaz; pencereye dokunulmaz. Geri çekilme: bir sonraki otomatik
        # deneme min_turns_between turn bekler (büyük pencerelerde brif
        # reddi her turn'de tekrarlanmasın).
        def drop_job(envelope, why:)
          @lock.synchronize do
            @pruners.delete(:__pending__)
            back_off!
          end
          Pruner.log_via(@dmesg, :warn, "prune job dropped (#{why}) — window untouched (#{envelope[:reason]})")
        end

        # Kuyruk taşması bir :completed olayını yuttuysa sicili dürüstçe
        # uzlaştır: sicil girdisi kalırsa kapı sonsuza dek "uçuşta" kalırdı.
        def discard_completion(payload)
          envelope = @lock.synchronize { @pruners.delete(payload[:id].to_s) }
          return unless envelope

          back_off!
          Pruner.log_via(@dmesg, :warn,
                         "pruner completion for #{payload[:id]} dropped (queue overflow) — ledger reconciled, window untouched")
        end

        # ---- Seam 3: worker thread'i (:subagent_completed işlenirken) -----

        # Sicilden @lock altında sil, KİLİDİ BIRAK, sonra supervisor.get +
        # doğrulama + aşamalama TEK kurtarma bölgesinde. Yabancı tamamlanma
        # (sicil ıskası) nil döner — iki harness birbirinin subagent'ını
        # asla işlemez. Dönüş: :staged | :rejected | :incomplete | :crashed | nil.
        def completion_event(payload)
          envelope = @lock.synchronize { @pruners.delete(payload[:id].to_s) }
          return nil unless envelope

          outcome = begin
            inst = @supervisor.respond_to?(:get) ? @supervisor.get(payload[:id].to_s) : nil
            finish_body = inst.respond_to?(:result) ? inst.result : nil
            if payload[:state].to_s != "completed" || finish_body.nil?
              :incomplete
            else
              plan, reason = Rules.validate_plan(finish_body, envelope[:units])
              if plan
                @lock.synchronize do
                  @staged = { plan: plan, target_tokens: envelope[:target_tokens],
                              ceiling: envelope[:ceiling], reason: envelope[:reason] }
                end
                :staged
              else
                Pruner.log_via(@dmesg, :warn, "pruner plan rejected (#{reason}) — dropped, window untouched")
                :rejected
              end
            end
          rescue StandardError => e
            Pruner.log_via(@dmesg, :warn, "pruner harvest crashed: #{e.class}: #{e.message} — plan dropped")
            :crashed
          end
          record_outcome(outcome, payload)
          outcome
        end

        # ---- Seam 4: turn thread'i (apply_staged_prune_plan!) -------------

        # Aşamalı planı atomik olarak al ve CANLI pencereye uygula
        # (Rules.apply_plan saf — kilit dışında). Başarı oran-limit
        # sayacını sıfırlar; başarısızlık planı düşürür, pencere olduğu
        # gibi kalır. Dönüş: [yeni_pencere, makbuz] veya nil.
        def take_staged!(live_window, config: {})
          staged = @lock.synchronize do
            s = @staged
            @staged = nil
            s
          end
          return nil unless staged

          candidate, detail = Rules.apply_plan(live_window, staged[:plan],
                                               target_tokens: staged[:target_tokens], config: config)
          if candidate
            receipt = detail
            @lock.synchronize do
              @turns_since_prune = 0
              @last_receipt = "dropped #{receipt[:dropped]}, summarized #{receipt[:summarized]} " \
                              "(#{receipt[:skipped_stale]} stale) — ~#{receipt[:before_tokens]} -> ~#{receipt[:after_tokens]} tokens"
            end
            [candidate, receipt]
          else
            @lock.synchronize do
              @turns_since_prune = 0 # canlı doğrulama düştü — geri çekilme
              @last_receipt = "failed live validation: #{detail}"
            end
            Pruner.log_via(@dmesg, :warn, "staged plan failed live validation (#{detail}) — window untouched")
            nil
          end
        end

        def status_bits
          @lock.synchronize do
            { in_flight: @pruners.any?, staged: !@staged.nil?,
              turns_since_prune: @turns_since_prune, last_receipt: @last_receipt }
          end
        end

        private

        # Hangi önkoşul eksikse adı adına söyle (karışık mesaj = teşhissiz
        # sessizlik): :no_bus / :no_supervisor / :no_type / true.
        def spawn_allowed_reason
          return :no_bus unless @event_bus.respond_to?(:subscribe)
          return :no_supervisor unless @supervisor.respond_to?(:spawn)
          return :no_type unless @supervisor.respond_to?(:type_registry) && @supervisor.type_registry.get(Harness::TYPE_NAME)

          true
        end

        # Başarısızlik sonrası geri çekilme + status'tan okunabilir iz:
        # "failed: <sonuç>" makbuzu, makbuz yalanı kapatır (asenkron kader
        # dmesg'te VE status'ta görünür).
        def record_outcome(outcome, payload)
          if outcome == :staged
            Pruner.log_via(@dmesg, :info, "pruner plan staged; applies at the next turn boundary")
            return
          end

          detail = case outcome
                   when :incomplete then "pruner subagent #{payload[:id]} finished incomplete " \
                                         "(state=#{payload[:state]}) — window untouched"
                   when :rejected then "pruner plan rejected — see the rejection line above"
                   when :crashed then "pruner harvest crashed — see the crash line above"
                   else return
                   end
          @lock.synchronize do
            @turns_since_prune = 0 # geri çekilme: ardışık doğum döngüsünü kır
            @last_receipt = "failed: #{outcome}"
          end
          Pruner.log_via(@dmesg, :warn, detail)
        end

        def back_off!
          @turns_since_prune = 0
        end

        def resolve_ceiling
          @ceiling_resolver.call
        end

        def fetch_cfg(key, default)
          @config.respond_to?(:fetch) ? @config.fetch(key, default) : default
        end
      end
    end
  end
end
