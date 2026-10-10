# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Talep düzlemi (goal-ledger planı A): !goal döngüsünün yapılandırılmış
    # ΔΣ defterinin masası. Pruner/vakanüvis emsali REQUIRES-görünürlük:
    # araç HER ZAMAN kayıtlıdır, model yüzünde yalnız GOAL_LEDGER coeffect'i
    # (çalışan !goal + knob ON) tatmininde görünür; Registry#get yolu ise
    # her zaman açık olduğundan kapalıyken dürüst hata verir. Ret
    # geri bildirimi C Validator'ın message+hint çiftinin birebir
    # yankısıdır — bounded-retry protokolünün model-bakan ucu.
    class UpdateGoalLedgerTool < BaseTool
      REQUIRES = [Rubik::Coeffects::GOAL_LEDGER].freeze

      DECLARATION = Declaration.new(
        name: "update_goal_ledger", aliases: ["ledger"],
        description: "Update the structured goal ledger of the RUNNING !goal loop with a " \
                     "JSON patch ({\"rev\": N, \"ops\": [{\"op\": ..., \"path\": ..., \"value\": ...}]}). " \
                     "Read the current ledger via read_file(path: 'rubik://goal/ledger') and issue the " \
                     "patch against the rev it reports. Rejections carry per-op fix hints; after the " \
                     "retry budget the ledger stays unchanged — read it and continue. A task status of " \
                     "`stale` means the harness re-checked that entry's verify predicate against the " \
                     "filesystem and it FAILED (the world drifted): re-inspect reality, then update the " \
                     "entry (including status) with a normal patch — a stale rev also means the ledger " \
                     "moved under you.",
        risk: :write, archetypes: [], write_grant: false,
        maestro_blocked: false, # vakanüvis/pruner emsali: kök düzlem aracı
        params_schema: {
          type: "object",
          properties: {
            patch: {
              type: "string",
              description: "JSON patch text ({\"rev\": N, \"ops\": [...]}) — rev must match the ledger's current rev."
            }
          },
          required: ["patch"]
        }
      )

      def initialize(runtime_context: nil)
        super(DECLARATION)
        @runtime_context = runtime_context
      end

      def execute(args = {})
        patch_text = args["patch"] || args[:patch]
        unless patch_text.is_a?(String) && !patch_text.strip.empty?
          return ToolOutput.error("update_goal_ledger: the 'patch' parameter is required — a JSON string " \
                                  "{\"rev\": N, \"ops\": [...]}.")
        end

        ledger = Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::GOAL_LEDGER, nil)
        unless ledger
          return ToolOutput.error("Goal ledger is not available: no running !goal loop (or goal.ledger.enabled=false). " \
                                  "The ledger exists only while a goal loop runs; update it after each meaningful step.")
        end

        render_result(ledger.update(patch_text))
      rescue StandardError => e
        ToolOutput.error("update_goal_ledger failed: #{e.class}: #{e.message} — the ledger is unchanged; " \
                         "read rubik://goal/ledger and retry.")
      end

      private

      def render_result(result)
        case result.status
        when :applied
          row = %(<goal_ledger_applied rev="#{result.rev}" uri="#{result.uri}" />)
          ToolOutput.ok(result.uri ? row : %(<goal_ledger_applied rev="#{result.rev}" storage="unavailable (memory-only)" />))
        when :exhausted
          ToolOutput.error("patch budget exhausted (consecutive rejections); the ledger is unchanged at rev " \
                           "#{result.rev}. Goal work may continue — read rubik://goal/ledger when you next " \
                           "update state, and issue a valid patch against that rev.")
        else
          lines = result.reasons.map do |reason|
            at = reason[:op_index].nil? ? "" : " (op #{reason[:op_index]})"
            "[#{reason[:class]}]#{at} #{reason[:path]}: #{reason[:message]} — #{reason[:hint]}"
          end
          ToolOutput.error("ledger patch rejected (rev still #{result.rev}):\n#{lines.join("\n")}")
        end
      end
    end
  end
end
