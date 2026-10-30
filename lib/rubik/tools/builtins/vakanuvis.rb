# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"
require_relative "../../storage/vakanuvis"

module Rubik
  module Tools
    # Talep düzlemi (plan 2026-10-04 §4.5, K7): maestro'nun kronikçi
    # masası. Dört eylemin hepsi Vakanüvis::Harness'e delege olur — recall
    # tamamen deterministiktir (LLM'siz), record/forget Düzlem 1 yazma
    # disipliniyle (ref minting, upsert, supersede) yazar, digest asenkron
    # kuyruklanır ve deterministik makbuz döner (maestro turn'ü asla LLM
    # bekletilmez). Görünürlük: yalnız kök/maestro düzlemi (archetypes
    # boş; ScopedRegistry ROOT_ONLY_TOOLS subagent kayıtlarına — self
    # dahil — kopyalamaz).
    class VakanuvisTool < BaseTool
      # Registry#schemas, REQUIRES memnuniyetsizliğinde aracı gizler:
      # kronikçi kapalıysa (subagents.vakanuvis.enabled=false ya da store
      # yok) bu masa model yüzünde görünmez.
      REQUIRES = [Rubik::Coeffects::VAKANUIS].freeze

      DECLARATION = Declaration.new(
        name: "vakanuvis", aliases: ["chronicler"],
        description: "Ask the background chronicler (compiled knowledge in rubik://storage): " \
                     "'recall' (deterministic digest over memory+wiki with source links — ask at task start), " \
                     "'record' (persist durable knowledge as a memory card; the ONE path for memory writes), " \
                     "'forget' (supersede/purge a mem.* card or a note), 'digest' (queue an async wiki compilation; " \
                     "returns a deterministic receipt, never blocks on the LLM), 'topics' (list recorded memory topics " \
                     "— orient before the first query), 'digest_status' (is my queued digest pending, in flight, or done?). " \
                     "Notes (annal.*) are the chronicler's evidence layer; memory cards are the durable conclusions you want recalled by default.",
        risk: :write, archetypes: [], write_grant: false,
        maestro_blocked: false, # storage emsali: kronikçi düzlemi kökte doğrudan
        params_schema: {
          type: "object",
          properties: {
            action: {
              type: "string", enum: ["recall", "record", "forget", "digest", "topics", "digest_status"],
              description: "Operation (default: 'recall')."
            },
            query: {
              type: "string",
              description: "recall/digest: knowledge query. Recall is keyword-AND — use 2-3 core terms (every " \
                           "space-separated term must literally appear); retry with other-language synonyms when empty."
            },
            types: {
              type: "array", items: { type: "string", enum: ["memory", "wiki", "note"] },
              description: "recall: entity scopes to search (default: memory + wiki)."
            },
            topic: { type: "string", description: "record: card topic — mints ref mem.<topic-slug> (upsert by topic)." },
            body: {
              type: "string",
              description: "record: card body (markdown; end it with a Keywords: line of 5-10 TR+EN synonyms if you " \
                           "can — a missing Keywords: line is auto-extracted from the body at write time)."
            },
            tags: {
              type: "array", items: { type: "string" },
              description: "record: optional recall tags (searched like body text; merged with the chronicler's vocabulary)."
            },
            links: {
              type: "object", additionalProperties: { type: "string" },
              description: "record: optional cross-references (e.g. {\"goal\": \"goal.1.<hash16>\"})."
            },
            ref: { type: "string", description: "forget: mem.* card or note ref (annal.*) — or id — to retire." }
          }
        }
      )

      def initialize(harness = nil, runtime_context: nil)
        super(DECLARATION)
        @harness = harness
        @runtime_context = runtime_context
      end

      def execute(args = {})
        action = (args["action"] || args[:action] || "recall").to_s
        harness = Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::VAKANUIS, @harness)
        unless harness
          return ToolOutput.error("Vakanüvis chronicler is not available: disabled by config " \
                                  "(subagents.vakanuvis.enabled=false) or no store wired.")
        end

        begin
          case action
          when "recall" then harness.recall(arg(args, "query"), types: arg(args, "types"))
          when "record"
            receipt = harness.record(topic: arg(args, "topic"), body: arg(args, "body"),
                                     links: arg(args, "links") || {}, tags: tags_arg(args))
            record_line(harness, receipt)
          when "forget"
            receipt = harness.forget(ref: arg(args, "ref"))
            forget_line(harness, receipt)
          when "digest" then harness.digest(arg(args, "query"))
          when "topics" then harness.topics
          when "digest_status" then harness.digest_status
          else ToolOutput.error("Unknown vakanuvis action '#{action}' " \
                                "(valid: recall, record, forget, digest, topics, digest_status).")
          end
        rescue ArgumentError => e
          ToolOutput.error("vakanuvis #{action}: #{e.message}")
        rescue StandardError => e
          Rubik::Storage::Vakanuvis.log_via(harness.dmesg, :warn, "vakanuvis #{action} failed: #{e.class}: #{e.message}")
          ToolOutput.error("vakanuvis #{action} failed: #{e.class}: #{e.message} — the store may be " \
                           "unavailable; retry the call or inspect dmesg(subsystem: 'storage').")
        end
      end

      private

      def record_line(harness, receipt)
        verb = receipt["skipped"] ? "unchanged (version #{receipt['version']} kept)" : "stored (version #{receipt['version']})"
        uri = harness.store.uri_for("memory", receipt["id"])
        line = "Recorded '#{receipt['ref']}': #{verb}.\nURI: #{uri}\nRecall it later: vakanuvis(action: 'recall', query: '...')"
        if receipt["keywords_extracted"]
          line += "\nKeywords auto-extracted from the body (no Keywords: line was present)."
        elsif receipt["keywords_state"] == "none"
          line += "\nWarning: no Keywords: line and none could be extracted — recall may miss this card; " \
                  "append a Keywords: line manually."
        end
        line
      end

      # Etiket paramı anahtar-varlığıyla okunur (tags: false sessizce []
      # düşmesin — review L3) ve dizi değilse storage aracıyla aynı virgül
      # bölmesine düşer (review CR#4: "a,b" tek ölü etiket olmasın).
      # Üst-seviye boolean/sayı ret edilir.
      def tags_arg(args)
        raw = if args.key?("tags") || args.key?(:tags)
                args["tags"] || args[:tags]
              else
                []
              end
        unless raw.is_a?(Array) || raw.is_a?(String)
          raise ArgumentError,
                "record tags must be an array of strings or a comma-separated string — " \
                "got #{raw.class} (#{raw.inspect})."
        end

        raw.is_a?(Array) ? raw : raw.to_s.split(",").map(&:strip)
      end

      def forget_line(harness, receipt)
        return "Nothing to forget: no memory card or note resolves from '#{receipt['ref']}'." unless receipt["forgot"]

        if receipt["mode"] == "purge"
          "Forgot '#{receipt['ref']}': row purged (hard delete)."
        else
          uri = harness.store.uri_for(receipt["type"] || "memory", receipt["id"])
          "Forgot '#{receipt['ref']}': superseded (status + trace link kept).\nURI: #{uri}"
        end
      end

      def arg(args, key, default = nil)
        args[key] || args[key.to_sym] || default
      end
    end
  end
end
