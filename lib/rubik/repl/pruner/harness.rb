# frozen_string_literal: true

require "monitor"
require_relative "../../concurrency"
require_relative "../../events"

module Rubik
  module REPL
    module Pruner
      # Düzlem 1 çekirdeği (Vakanüvis::Harness yapısı): tek worker thread
      # + sınırlı FIFO (Concurrency::Worker iskeleti: atomik kabul,
      # idempotent kapanış, busy sayımı ve son-çare ağı iskelettedir).
      # ANLIK GÖRÜNTÜ her zaman ÇAĞIRAN thread'de alınır
      # (:turn_finished abonelik bloğu turn thread'inde koşar; araç/komut
      # çağrısı da turn thread'indedir) — worker shell durumuna ASLA
      # dokunmaz; o yalnız brif kurar, doğurur, hasat eder ve planı
      # aşamalar. Sessizlik sözleşmesi: "Context Pruner" SILENT_ROLES'tadır
      # — notice yok, wake yok, yalnız dmesg. Uygulama (pencere takası)
      # yalnız turn thread'inde, apply_staged_prune_plan! üzerinden.
      class Harness
        include Concurrency::Worker

        # STOP işareti iskeletin tek ev sahibinde; sabit adı yaşar.
        STOP = Concurrency::Worker::STOP
        MAX_QUEUE = 16
        # Olay adları tek evden okunur: Rubik::Events bağımlılıksız bir
        # yapraktır (uris.rb öncülü) — izolasyon doktrini bozulmadan isimler
        # yayıncı ve abonede aynı kaynaktan düşer.
        TURN_EVENT = Rubik::Events::TURN_FINISHED
        COMPLETED_EVENT = Rubik::Events::SUBAGENT_COMPLETED
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

        # ---- olay giriş kapısı ----------------------------------------------

        # Atomik kabul (stopped-kontrol + push tek kritik bölümde) iskelette:
        # kapanış yarışındaki olay ya STOP'tan önce düşer ve işlenir ya da
        # reddedilir — işleyeneksiz bir olay busy sayımını sızdıramaz.
        def enqueue_event(kind, payload)
          unless payload.is_a?(Hash)
            Pruner.log_via(@dmesg, :warn, "discarded non-hash #{kind} event (#{payload.class})")
            return false
          end
          super
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
          # A completion refused at teardown drops without gate reconcile —
          # terminal by design: the session is ending, nothing reads the
          # gate afterwards.
          @event_bus.subscribe(COMPLETED_EVENT, context: @context) { |p| enqueue_event(:completed, p) }
        end

        def enqueue_job(envelope)
          enqueue_event(:job, { envelope: envelope })
        end

        # ---- Concurrency::Worker iskelet kancaları --------------------------

        def worker_max_queue = MAX_QUEUE

        def worker_warn(message) = Pruner.log_via(@dmesg, :warn, message)

        # Taşma düşürmesi gate'in izini uzlaştırır — :job yer tutucusu
        # temizlenir, :completed sicil girdisi silinir (kapı asla "uçuşta"
        # takılı kalamaz) ve taşan tamamlanmanın id'si loglanır.
        def worker_drop_accounted(item)
          if item[0] == :job
            @gate.drop_job(item[1][:envelope], why: "queue overflow")
          elsif item[0] == :completed
            @gate.discard_completion(item[1])
          end
          Pruner.log_via(@dmesg, :warn, "event queue overflow — dropped oldest #{item[0]} event")
        end

        def worker_dispatch_failed(kind, payload, error)
          # A lost dispatch must reconcile the gate like an overflow drop —
          # an unreconciled :job placeholder or :completed entry would wedge
          # every later prune behind "already in flight".
          case kind
          when :job
            @gate.drop_job(payload[:envelope], why: "dispatch failed") if payload.is_a?(Hash)
          when :completed
            @gate.discard_completion(payload) if payload.is_a?(Hash)
          end
          Pruner.log_via(@dmesg, :warn, "pruner worker event dispatch failed (#{error.class}: #{error.message}) — worker continues")
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
