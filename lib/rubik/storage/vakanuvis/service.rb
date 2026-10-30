# frozen_string_literal: true

require_relative "../layout"

module Rubik
  module Storage
    module Vakanuvis
      # Kompozisyon kökü kancası (repl/lifecycle.rb Phase 4, Storage::
      # Service.register'dan hemen sonra — STORE coeffect'i çözülebilir
      # olmalı): kronikçi açıksa Harness kurulur, kendi child ctx'inde
      # yaşar (abonelik + worker geri alımları orada), VAKANUIS coeffect'i
      # köke sağlanır (talep düzlemi aracı buradan çözer). Kapalıysa
      # (subagents.vakanuvis.enabled=false) nil döner — kronikçi yok,
      # aracı REQUIRES karşılanmaz ve model yüzünde görünmez.
      module Service
        module_function

        # Test zırhı: RUBIK_TEST=1 ortamında (tüm test süiti) kronikçi
        # varsayılan KAPALI bağlanır — gerçek shell'lerle koşan scripted
        # provider testlerinde arka plan damıtıcı doğumları yarış açar.
        # RUBIK_VAKANUIS_FORCE=1 zırhı devre dışı bırakır (kronikçinin
        # kendi bağlama testleri); üretimde zırh yok, K1 gereği AÇIK.
        def enabled?(config = nil)
          return false if ENV["RUBIK_TEST"] == "1" && ENV["RUBIK_VAKANUIS_FORCE"] != "1"

          Layout.config_get(config, "subagents.vakanuvis.enabled", true)
        end

        def bind(context_or_manager, config: nil, event_bus: nil)
          return nil unless enabled?(config)

          ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
          return nil unless ctx.respond_to?(:provide)

          store = Rubik::Coeffects.get(ctx, Rubik::Coeffects::STORAGE_STORE)
          unless store
            Rubik::Log.warn(:storage, "vakanuvis not bound: STORAGE_STORE coeffect unsatisfied " \
                                      "(storage.enabled=false or boot-order gap)")
            return nil
          end

          child = ctx.respond_to?(:extend) ? ctx.extend : nil
          unless child
            Rubik::Log.warn(:storage, "vakanuvis bound without a disposable child ctx — worker and " \
                                      "subscriptions live for the process lifetime")
          end
          unless event_bus.respond_to?(:subscribe)
            Rubik::Log.warn(:storage, "vakanuvis bound without an event bus — the distiller stays " \
                                      "dormant (digests queue, no harvest path)")
          end

          harness = Harness.new(
            store: store, config: config, event_bus: event_bus,
            supervisor: Rubik::Coeffects.get(ctx, Rubik::Coeffects::SUBAGENT_SUPERVISOR),
            dmesg: Rubik::Coeffects.get(ctx, Rubik::Coeffects::DMESG),
            context: child, session_slug: nil
          )
          # Ömür (§2.7): child ctx'in cascade inverse'i worker'ı kapatır;
          # kuyruk FIFO'su drain olur, yarım kronik kalmaz.
          child&.on_dispose do
            harness.shutdown
            ctx.unprovide(Rubik::Coeffects::VAKANUIS) if ctx.respond_to?(:unprovide) && ctx.get(Rubik::Coeffects::VAKANUIS).equal?(harness)
          end
          Orientation.register_hook(ctx, harness, config: config, inverse_ctx: child)
          harness.start!
          ctx.provide(Rubik::Coeffects::VAKANUIS, harness)
          context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)
          harness
        end
      end
    end
  end
end
