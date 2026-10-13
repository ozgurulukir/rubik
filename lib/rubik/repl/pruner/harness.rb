# frozen_string_literal: true

require "monitor"

module Rubik
  module REPL
    module Pruner
      # Düzlem 1 çekirdeği (Vakanüvis::Harness yapısı): tek worker thread
      # + sınırlı FIFO. ANLIK GÖRÜNTÜ her zaman ÇAĞIRAN thread'de alınır
      # (:turn_finished abonelik bloğu turn thread'inde koşar; araç/komut
      # çağrısı da turn thread'indedir) — worker shell durumuna ASLA
      # dokunmaz; o yalnız brif kurar, doğurur, hasat eder ve planı
      # aşamalar. Sessizlik sözleşmesi: "Context Pruner" SILENT_ROLES'tadır
      # — notice yok, wake yok, yalnız dmesg. Uygulama (pencere takası)
      # yalnız turn thread'inde, apply_staged_prune_plan! üzerinden.
      class Harness
        STOP = :__pruner_stop__
        MAX_QUEUE = 16
        TURN_EVENT = :turn_finished # TurnRecorder::TURN_EVENT_TARGET ile eş pinli
        COMPLETED_EVENT = :subagent_completed
        TYPE_NAME = "pruner"
        PRUNER_ROLE = "Context Pruner"

        attr_reader :shell, :supervisor, :dmesg, :gate

        def initialize(shell:, config: nil, event_bus: nil, supervisor: nil, dmesg: nil, context: nil)
          @shell = shell
          @config = config
          @event_bus = event_bus
          @supervisor = supervisor
          @dmesg = dmesg
          @context = context
          @queue = Thread::Queue.new
          @monitor = Monitor.new
          @busy = 0
          @stopped = false
          @worker = nil
          @gate = Gate.new(shell: shell, config: config, supervisor: supervisor, dmesg: dmesg,
                           event_bus: event_bus, ceiling_resolver: method(:resolve_ceiling))
        end

        # ---- yaşam döngüsü ---------------------------------------------------

        def start!
          subscribe_events
          @worker = Thread.new { run_worker }
          @worker.name = "rubik-pruner" if @worker.respond_to?(:name=)
          self
        end

        def stopped? = @monitor.synchronize { @stopped }

        # Dispose sözleşmesi (vakanüvis): FIFO drain olur (STOP dahil önceki
        # olaylar işlenir), thread 2 saniyede durmazsa kill + dürüst dmesg.
        def shutdown
          @monitor.synchronize { @stopped = true }
          @monitor.synchronize { @busy += 1 }
          @queue.push(STOP)
          @worker&.join(2)
          if @worker&.alive?
            Pruner.log_via(@dmesg, :warn, "worker did not stop in 2s — killing with #{queue_size} event(s) unprocessed")
            @worker.kill
          end
          @worker = nil
        end

        def wait_idle(timeout: 10.0)
          deadline = Time.now + timeout
          sleep 0.01 while busy? && Time.now < deadline
          !busy?
        end

        def busy? = @monitor.synchronize { @busy.positive? }

        def queue_size = @queue.size

        # ---- talep düzlemi (prune_context aracı / !prune komutu) ----------

        # Zorunlu budama isteği: LLM asla bekletilmez — deterministik makbuz
        # döner. Kuyruk reddi (kapanış yarışı) yer tutucuyu temizler ve dürüst
        # ret makbuzu döner (makbuz asla kuyruğa girmeyen işe söz vermez).
        def prune(reason: "manual")
          envelope, skip = @gate.stage_job(@shell.conversation_history, reason: reason, forced: true)
          return decline_receipt(skip) unless envelope

          if !stopped? && enqueue_job(envelope)
            "Prune queued (async): the pruner will propose a keep/drop/summarize plan for the ROOT window; " \
              "it is validated deterministically and applied at the next turn boundary. " \
              "This call did NOT wait for the LLM. Reason: #{reason}."
          else
            @gate.drop_job(envelope, why: "harness stopped")
            decline_receipt(:stopped)
          end
        end

        # ---- turn sınırı uygulama kapısı (TurnRecorder çağırır) -----------

        # Aşamalı planı canlı pencereye uygular; dönüş [yeni_pencere,
        # makbuz] veya nil (plan yok / canlı doğrulama düşürdü).
        def take_applicable_plan!(live_window)
          @gate.take_staged!(live_window, config: compaction_config)
        end

        def status_text
          Rules.status_report(window: @shell.conversation_history, ceiling: resolve_ceiling,
                              bits: @gate.status_bits)
        end

        private

        def subscribe_events
          return unless @event_bus.respond_to?(:subscribe)

          # Anlık görüntü abonelik bloğunda alınır. DÜRÜST NOT: bus post'u
          # fire-and-forget'tir — blok rubik-kworker thread'inde koşar, turn
          # thread'i DEĞİLDİR; okuma bir sonraki turn'ün pencere mutasyonuyla
          # yarışabilir. Güvenlik apply katmanından gelir: hash8 yeniden
          # doğrulaması yarışan birimleri "bayat op" olarak atlar (sayılır),
          # uygulama-sonu değişmezleri ve kopyala-doğrula-takas pencereyi
          # bozulmadan korur — yarış en fazla bir planın düşmesine mal olur.
          @event_bus.subscribe(TURN_EVENT, context: @context) do |_payload|
            @gate.note_turn!
            envelope, = @gate.stage_job(@shell.conversation_history, reason: "turn", forced: false)
            @gate.drop_job(envelope, why: "harness stopped") if envelope && !enqueue_job(envelope)
          end
          @event_bus.subscribe(COMPLETED_EVENT, context: @context) { |p| enqueue_event(:completed, p) }
        end

        def enqueue_job(envelope)
          enqueue_event(:job, { envelope: envelope })
        end

        def enqueue_event(kind, payload)
          return false if stopped?

          unless payload.is_a?(Hash)
            Pruner.log_via(@dmesg, :warn, "discarded non-hash #{kind} event (#{payload.class})")
            return false
          end

          drop_oldest! if @queue.size >= MAX_QUEUE
          @monitor.synchronize { @busy += 1 }
          @queue.push([kind, payload])
          true
        end

        # Taşma düşürmesi asla STOP'u yutamaz (vakanüvis kuralı); düşen
        # işin gate'teki izi uzlaştırılır — :job yer tutucusu temizlenir,
        # :completed sicil girdisi silinir (kapı asla "uçuşta" takılı
        # kalamaz) ve taşan tamamlanmanın id'si loglanır.
        def drop_oldest!
          item = @queue.pop(true)
          if item == STOP
            @queue.push(STOP)
          else
            @monitor.synchronize { @busy -= 1 }
            if item[0] == :job
              @gate.drop_job(item[1][:envelope], why: "queue overflow")
            elsif item[0] == :completed
              @gate.discard_completion(item[1])
            end
            Pruner.log_via(@dmesg, :warn, "event queue overflow — dropped oldest #{item[0]} event")
          end
        rescue ThreadError
          nil
        end

        def run_worker
          loop do
            kind, payload = @queue.pop
            break if kind == STOP

            handle_event(kind, payload)
          ensure
            @monitor.synchronize { @busy -= 1 }
          end
        end

        # Pruner'in kendi hatası REPL akışını asla bozmaz — uyarı düşer,
        # sonraki olay işlenir (TranscriptIndexer disiplini).
        def handle_event(kind, payload)
          case kind
          when :job then handle_job(payload[:envelope])
          when :completed then @gate.completion_event(payload)
          end
        rescue StandardError => e
          Pruner.log_via(@dmesg, :warn, "event handling failed (#{kind}): #{e.class}: #{e.message}")
        end

        def handle_job(envelope)
          brief = Brief.build(units: envelope[:units], ceiling: envelope[:ceiling],
                              target_tokens: envelope[:target_tokens], trigger_ratio: envelope[:trigger_ratio],
                              max_chars: envelope[:brief_budget_chars])
          return @gate.drop_job(envelope, why: "brief over the hard bound") unless brief

          envelope[:brief] = brief
          @gate.spawn_job(envelope)
        end

        def decline_receipt(skip)
          case skip
          when :busy then "A pruner run is already in flight — this request was not duplicated."
          when :staged then "A validated prune plan is already staged and applies at the next turn boundary."
          when :no_ceiling then "Prune declined: the effective input ceiling is unknown for the current model."
          when :stopped then "Prune declined: the pruner harness is not running (session teardown)."
          else "Prune declined (#{skip})."
          end
        end

        # Koruma bantları context.* SSOT'sundan (preserve_first_n/last_n).
        def compaction_config
          {
            "preserve_first_n" => fetch_cfg("context.preserve_first_n", 2),
            "preserve_last_n" => fetch_cfg("context.preserve_last_n", 6)
          }
        end

        # trim_conversation_window! ile aynı tavan çözümü (sticky damgalı
        # model spec'i + llm_registry; hata → nil → kapı atlar).
        def resolve_ceiling
          spec = @shell.current_model_spec
          return nil unless spec.is_a?(Hash) && @shell.respond_to?(:llm_registry) && @shell.llm_registry

          @shell.llm_registry.effective_input_limit_for(spec["provider"], spec["name"])
        rescue StandardError => e
          Pruner.log_via(@dmesg, :warn, "input ceiling lookup failed (#{e.class}: #{e.message}); prune gate skipped")
          nil
        end

        def fetch_cfg(key, default)
          @config.respond_to?(:fetch) ? @config.fetch(key, default) : default
        end
      end
    end
  end
end
