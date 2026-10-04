# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"
require_relative "../../uris"
require_relative "../../storage"

module Rubik
  module Tools
    # rubik://storage sanal FS-DB'nin yazma düzlemi (okuma düzlemi read_file
    # URI rotalarıdır — research archetype'ı storage aracına gerek olmadan
    # okur). maestro ve coder subagent'ları hedef/plan/bellek/wiki/transcript/
    # inceleme/not varlıklarını buradan yazar; worktree'ye iş dosyası
    # saçtırmadan merkezi depo tutar.
    class StorageTool < BaseTool
      # Registry#schemas, REQUIRES memnuniyetsizliğinde aracı gizler (storage
      # kapalı/bağlanmamışken reklam edilmez); plain (ctx'siz) registry'ler
      # her şeyi reklam etmeye devam eder.
      REQUIRES = [Rubik::Coeffects::STORAGE_STORE].freeze

      attr_accessor :store, :runtime_context

      DECLARATION = Declaration.new(
        name: "storage", aliases: ["rubik_storage"],
        description: "Central rubik://storage database for goals, plans, memory, wiki, transcripts, reviews, " \
                     "and notes. Actions: 'put' (create/update; returns id rubik://storage URI), 'get', 'list', " \
                     "'search', 'set_ref' (alias), 'delete'. Keep agent workfiles HERE — not in the worktree. " \
                     "Read back any entity with read_file path 'rubik://storage/<type>/<id>'.",
        risk: :write, archetypes: [:coder], write_grant: true,
        maestro_blocked: false, # storage plane stays direct at root (TOOLS.md maestro policy)
        params_schema: {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: ["put", "get", "list", "search", "set_ref", "delete"],
              description: "Operation (default: 'list')."
            },
            type: {
              type: "string",
              enum: Rubik::Storage::Store::TYPES,
              description: "Entity type: goal, plan, memory, wiki, transcript, review, or note."
            },
            title: { type: "string", description: "Entity title (required for put)." },
            body: { type: "string", description: "Entity body (markdown text)." },
            tags: {
              type: "array", items: { type: "string" },
              description: "Tags (array or comma-separated string)."
            },
            links: {
              type: "object", additionalProperties: { type: "string" },
              description: "Cross-references, e.g. {\"goal\": \"goal.1.<hash16>\"}."
            },
            status: { type: "string", description: "Lifecycle status (default 'active')." },
            id: { type: "string", description: "Entity id to update/get/delete: full 'plan.3.<hash16>', 'plan.3', row '3', hash prefix, or ref alias." },
            ref: { type: "string", description: "Alias name bound to the entity (upsert semantics)." },
            query: { type: "string", description: "Search query; every space-separated term must appear (case-insensitive over title/body/tags)." },
            format: { type: "string", enum: ["markdown", "json"], description: "Output format (default markdown)." }
          }
        }
      )
      def initialize(store = nil, runtime_context: nil, config: nil, root_dir: Dir.pwd)
        super(DECLARATION)
        @store = store
        @runtime_context = runtime_context
        @config = config
        @root_dir = root_dir
      end

      def execute(args = {})
        store = resolve_store
        unless store
          return ToolOutput.error("Storage is not available: disabled by config (storage.enabled=false) or no store wired. " \
                                  "Read-only rubik://storage URIs may still resolve if a store exists.")
        end

        action = (args["action"] || args[:action] || "list").to_s
        json = (args["format"] || args[:format]).to_s == "json"

        case action
        when "put" then handle_put(store, args, json)
        when "get" then handle_get(store, args, json)
        when "list" then handle_list(store, args, json)
        when "search" then handle_search(store, args, json)
        when "set_ref" then handle_set_ref(store, args)
        when "delete" then handle_delete(store, args)
        else ToolOutput.error("Unknown storage action '#{action}' (valid: put, get, list, search, set_ref, delete).")
        end
      rescue ArgumentError => e
        ToolOutput.error("storage #{action}: #{e.message}")
      rescue StandardError => e
        ToolOutput.error("storage error: #{e.class}: #{e.message}")
      end

      private

      # Üçlü zincir (Tools::Services ev hükümleri): ctor enjeksiyonu →
      # STORAGE_STORE coeffect'i (parent chain — subagent'lar buradan çözer)
      # → config'e dayalı tembel fresh default (storage kapalıysa nil).
      def resolve_store
        resolved = Rubik::Coeffects.resolve(@runtime_context, Rubik::Coeffects::STORAGE_STORE, @store)
        return resolved if resolved

        @resolve_store ||= Rubik::Storage::Service.build(config: @config, root_dir: @root_dir)
      end

      def handle_put(store, args, json)
        record = store.put(
          type: arg(args, "type"), title: arg(args, "title").to_s,
          body: arg(args, "body", ""), tags: normalize_tags(args),
          links: arg(args, "links", {}) || {}, status: arg(args, "status", "active"),
          id: arg(args, "id"), ref: arg(args, "ref")
        )
        return JSON.pretty_generate(record) if json

        uri = store.uri_for(record["type"], record["id"])
        <<~MD
          Stored: #{record['id']} (version #{record['version']})
          URI: #{uri}
          Read back: read_file(path: '#{uri}')
        MD
      end

      def handle_get(store, args, json)
        type = arg(args, "type").to_s
        id = arg(args, "id").to_s
        record = store.get(type: type, id: id)
        unless record
          return ToolOutput.error("Entity not found: #{type}/#{id} in project '#{store.project}'. " \
                                  "Use action 'list' to see existing ids.")
        end

        json ? JSON.pretty_generate(record) : Rubik::Storage::Render.entity(record, project: store.project)
      end

      def handle_list(store, args, json)
        type = arg(args, "type")
        summaries = store.list(type: type)
        return JSON.pretty_generate(summaries.map(&:to_h)) if json

        type_label = type || "all types"
        uri_hint = "read_file #{Rubik::Uris.storage_listing(project: store.project, type: type_label)}/<id>"
        Rubik::Storage::Render.listing(project: store.project, type: type_label, summaries: summaries.map(&:to_h),
                                       uri_hint: uri_hint)
      end

      def handle_search(store, args, json)
        query = arg(args, "query").to_s
        return ToolOutput.error "storage search: 'query' is required." if query.strip.empty?

        hits = store.search(query: query, type: arg(args, "type"))
        return "No storage entities match '#{query}'." if hits.empty?

        return JSON.pretty_generate(hits) if json

        hits.map { |r| "#{r['id']} — #{r['title']} (#{r['status']})" }.join("\n")
      end

      def handle_set_ref(store, args)
        result = store.set_ref(arg(args, "ref").to_s, arg(args, "id").to_s)
        "Ref set: #{result['ref']} → #{result['id']}\nURI: #{result['uri']}"
      end

      def handle_delete(store, args)
        deleted = store.delete(type: arg(args, "type").to_s, id: arg(args, "id").to_s)
        return ToolOutput.error("Entity not found: #{arg(args, 'type')}/#{arg(args, 'id')}") unless deleted

        "Deleted: #{deleted['id']} (row #{deleted['row']} is never reused)."
      end

      def arg(args, key, default = nil)
        args[key] || args[key.to_sym] || default
      end

      def normalize_tags(args)
        raw = arg(args, "tags", [])
        return raw if raw.is_a?(Array)

        # Dize olarak gelen etiketler virgülle ayrılır (LLM klavye alışkanlığı).
        raw.to_s.split(",").map(&:strip)
      end
    end
  end
end
