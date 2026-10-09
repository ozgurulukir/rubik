# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Talep düzlemi (context-pruner planı 2026-10-09): maestro'nun pencere
    # budayıcı masası. İki eylem de Pruner::Harness'e delege olur — 'prune'
    # asenkron kuyruklanır ve deterministik makbuz döner (maestro turn'ü
    # asla LLM bekletilmez; plan turn sınırında uygulanır), 'status' tamamen
    # deterministiktir. Görünürlük: REQUIRES memnuniyetsizse (knob kapalı)
    # araç model yüzünde görünmez; ROOT_ONLY_TOOLS subagent düzlemlerine
    # (self dahil) asla kopyalanmaz — kök penceresini yalnız kök budar.
    # Mimari sınır: tools çekirdeği repl/'e require edemez — harness sınıfı
    # ana yükleme ağacından (repl.rb → repl/pruner) gelir, burada yalnız
    # duck-typed çağrılır.
    class PruneContextTool < BaseTool
      REQUIRES = [Rubik::Coeffects::PRUNER].freeze

      DECLARATION = Declaration.new(
        name: "prune_context", aliases: ["pruner"],
        description: "Clean the ROOT conversation window (semi-deterministic: an LLM proposes a " \
                     "keep/drop/summarize plan; the harness validates it deterministically and applies " \
                     "it at the next turn boundary — goal/task turns and recent context are always " \
                     "preserved): 'prune' (queue a forced prune now; returns a deterministic receipt, " \
                     "never blocks on the LLM), 'status' (window estimate vs ceiling, staged plan " \
                     "state, last receipt).",
        risk: :write, archetypes: [], write_grant: false,
        maestro_blocked: false, # vakanüvis emsali: budayıcı düzlemi kökte doğrudan
        params_schema: {
          type: "object",
          properties: {
            action: {
              type: "string", enum: ["prune", "status"],
              description: "Operation (default: 'status')."
            },
            reason: { type: "string", description: "prune: optional one-line motive recorded in dmesg." }
          }
        }
      )

      def initialize(harness = nil, runtime_context: nil)
        super(DECLARATION)
        @harness = harness
        @runtime_context = runtime_context
      end

      def execute(args = {})
        action = (args["action"] || args[:action] || "status").to_s
        harness = Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::PRUNER, @harness)
        unless harness
          return ToolOutput.error("Context pruner is not available: disabled by config " \
                                  "(subagents.pruner.enabled=false, the default) or the harness is not wired.")
        end

        begin
          case action
          when "prune" then harness.prune(reason: arg(args, "reason") || "maestro")
          when "status" then harness.status_text
          else ToolOutput.error("Unknown prune_context action '#{action}' (valid: prune, status).")
          end
        rescue ArgumentError => e
          ToolOutput.error("prune_context #{action}: #{e.message}")
        rescue StandardError => e
          # Duck-typed dmesg halkası (tools çekirdeği repl/pruner'ı require
          # edemez — mimari sınır): ring varsa oraya, yoksa Log'a.
          dmesg = harness.respond_to?(:dmesg) ? harness.dmesg : nil
          if dmesg.respond_to?(:log)
            dmesg.log(:repl, :warn, "prune_context #{action} failed: #{e.class}: #{e.message}")
          else
            Rubik::Log.warn(:repl, "prune_context #{action} failed: #{e.class}: #{e.message}")
          end
          ToolOutput.error("prune_context #{action} failed: #{e.class}: #{e.message} — retry the call " \
                           "or inspect dmesg(subsystem: 'repl').")
        end
      end

      private

      def arg(args, key, default = nil)
        args[key] || args[key.to_sym] || default
      end
    end
  end
end
