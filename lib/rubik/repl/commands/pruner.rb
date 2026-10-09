# frozen_string_literal: true

require_relative "base"
require_relative "../../coeffects"

module Rubik
  module REPL
    module Commands
      # !prune — KÖK pencere budayıcısının kullanıcı tarafı (context-pruner
      # planı 2026-10-09). !storage emsali: coeffect üzerinden çözer, kapalıyken
      # dürüstçe kapalı der (knob operator-only: subagents.pruner.*).
      # "now" zorunlu budama kuyruklar (deterministik makbuz; LLM asla
      # bekletilmez — plan turn sınırında uygulanır), "status" durum raporu.
      module Pruner
        extend Base

        USAGE_PRUNE = "Usage: !prune [now|status]"

        def self.register(shell)
          handler = lambda do |args, ctx|
            harness = resolve_pruner(ctx)
            unless harness
              ctx.out.puts unbound_message(ctx)
              next
            end

            sub = args.first.to_s.downcase
            if ["status", ""].include?(sub)
              ctx.out.puts harness.status_text
            elsif ["now", "run", "force"].include?(sub)
              ctx.out.puts harness.prune(reason: "user")
            else
              ctx.out.puts USAGE_PRUNE
            end
          end

          shell.register_command(
            "prune",
            description: "Clean the ROOT conversation window via the context pruner (!prune status for details)",
            usage: USAGE_PRUNE,
            audience: :both,
            &handler
          )
        end

        def self.resolve_pruner(ctx)
          rt = ctx.respond_to?(:runtime_manager) ? ctx.runtime_manager : nil
          rt&.context ? Rubik::Coeffects.get(rt.context, Rubik::Coeffects::PRUNER) : nil
        end

        # Knob kapalı ile AÇIK-AMA-BAĞLANAMAMIŞ ayrımı (review 2026-10-09):
        # ikincisi ayarı zaten açık olan operatörü sonsuz "enable et" döngüsüne
        # sokardı — teşhis (boot warn + dmesg) adı adına söylenir.
        def self.unbound_message(ctx)
          knob = begin
            ctx.config.fetch("subagents.pruner.enabled", false)
          rescue StandardError
            false
          end
          if knob == true
            "Context pruner is ENABLED but did not bind (boot-order gap or missing supervisor — see the " \
              "startup warning / dmesg). Fix the reported cause and restart the session."
          else
            "Context pruner is off (the default). An operator can enable it with: " \
              "!config set subagents.pruner.enabled true [--project|--global], then restart the session."
          end
        end
      end
    end
  end
end
