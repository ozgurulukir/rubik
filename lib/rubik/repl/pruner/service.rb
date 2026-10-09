# frozen_string_literal: true

module Rubik
  module REPL
    module Pruner
      # Kompozisyon kökü kancası (repl/lifecycle.rb Phase 4, Vakanüvis
      # bind'inden hemen sonra — SHELL/SUPERVISOR/DMESG coeffect'leri Faz
      # 2'den çözülebilir olmalı): budayıcı açıksa Harness kurulur, kendi
      # child ctx'inde yaşar (abonelik geri alımları orada), PRUNER
      # coeffect'i köke sağlanır (prune_context aracı buradan çözer;
      # apply_staged_prune_plan! da). Kapalıysa
      # (subagents.pruner.enabled=false — DEFAULT) nil döner: budayıcı
      # yok, araç REQUIRES karşılanmaz ve model yüzünde görünmez, REPL
      # komutu dürüstçe kapalı der.
      module Service
        module_function

        # Test zırhı (vakanüvis emsali): RUBIK_TEST=1 ortamında budayıcı
        # varsayılan KAPALI bağlanır — scripted shell testleri arka plan
        # doğumlarıyla yarışmasın. RUBIK_PRUNER_FORCE=1 zırhı kaldırır
        # (budayıcının kendi testleri). Knob zaten DEFAULT OFF.
        def enabled?(config = nil)
          return false if ENV["RUBIK_TEST"] == "1" && ENV["RUBIK_PRUNER_FORCE"] != "1"

          config_get(config, "subagents.pruner.enabled", false)
        end

        def bind(context_or_manager, config: nil, event_bus: nil)
          return nil unless enabled?(config)

          ctx = context_or_manager.respond_to?(:context) ? context_or_manager.context : context_or_manager
          return nil unless ctx.respond_to?(:provide)

          shell = Rubik::Coeffects.get(ctx, Rubik::Coeffects::SHELL)
          unless shell
            Rubik::Log.warn(:repl, "pruner not bound: SHELL coeffect unsatisfied (boot-order gap)")
            return nil
          end
          supervisor = Rubik::Coeffects.get(ctx, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
          unless supervisor
            Rubik::Log.warn(:repl, "pruner not bound: SUBAGENT_SUPERVISOR coeffect unsatisfied — no spawn path")
            return nil
          end
          Rubik::Log.warn(:repl, "pruner bound without an event bus — the LLM half stays dormant (no harvest path)") unless event_bus.respond_to?(:subscribe)

          child = ctx.respond_to?(:extend) ? ctx.extend : nil
          unless child
            Rubik::Log.warn(:repl, "pruner bound without a disposable child ctx — worker and " \
                                   "subscriptions live for the process lifetime")
          end

          harness = Harness.new(
            shell: shell, config: config, event_bus: event_bus,
            supervisor: supervisor, dmesg: Rubik::Coeffects.get(ctx, Rubik::Coeffects::DMESG),
            context: child
          )
          # Ömür (§2.7): child ctx'in cascade inverse'i worker'ı kapatır.
          child&.on_dispose { harness.shutdown }
          harness.start!
          ctx.provide(Rubik::Coeffects::PRUNER, harness)
          context_or_manager.reconcile_all if context_or_manager.respond_to?(:reconcile_all)
          harness
        end

        # Noktalı anahtar okuması iki config şeklinde de aynı çalışsın
        # (maestro_gate.rb:38-40 düzeni): Rubik::Config#fetch noktalı yolu
        # böler, düz Hash hepsini tek anahtar sayar → dig'e düş.
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
    end
  end
end
