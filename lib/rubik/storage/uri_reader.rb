# frozen_string_literal: true

require_relative "layout"
require_relative "store"
require_relative "render"
require_relative "../coeffects"

module Rubik
  module Storage
    # rubik://storage URI çözümleyicisi — read_file (files.rb) rotası satır
    # sınırı yüzünden buraya delege edilir. String (başarı) ya da ToolOutput
    # (dürüst hata) döndürür; ToolOutput require edilmez: çağıran tools
    # katmanı (builtins barrel) onu her zaman daha önce yüklemiştir.
    #
    #   rubik://storage/index[.json]                  — merkezi indeks
    #   rubik://storage/<project>[.json]              — proje özeti
    #   rubik://storage/<project>/<type>[.json]       — tip listesi
    #   rubik://storage/<project>/<type>/<id>[.json]  — varlık (id/satır/
    #                                                    karma öneki)
    #   rubik://storage/<project>/refs/<alias>        — alias çözümü
    #   rubik://storage/<type>/...                    — varsayılan proje
    module UriReader
      module_function

      RESERVED = ["index", "refs", "storage"].freeze

      def read(path, ctx: nil)
        store = Rubik::Coeffects.get(ctx, Rubik::Coeffects::STORAGE_STORE)
        return unavailable unless store

        segments = path.sub(%r{\Arubik://storage(?:/|\z)}i, "").split("/")
                       .reject(&:empty?).map(&:strip)
        return malformed(path) if segments.empty?

        json = false
        if segments.last.match?(/\.json\z/i)
          segments[-1] = segments.last.sub(/\.json\z/i, "")
          json = true
        end

        render(store, normalize(store, segments), json: json)
      rescue StandardError => e
        Rubik::Tools::ToolOutput.error("rubik://storage read failed: #{e.class}: #{e.message}")
      end

      def normalize(store, segments)
        return { kind: :index, segments: [] } if segments == ["index"]
        return { kind: :projectless_refs, segments: segments } if segments.first == "refs"

        if Store::TYPES.include?(segments.first.to_s.downcase)
          { kind: :scoped, project: store.project, segments: segments }
        else
          { kind: :scoped, project: Layout.slugify(segments.first.to_s), segments: segments[1..] || [] }
        end
      end

      def render(store, parsed, json:)
        return malformed_refs if parsed[:kind] == :projectless_refs
        return render_index(store, json) if parsed[:kind] == :index

        project = parsed[:project]
        # Çapraz-proje okumalar hedef projenin Store görünümünden yapılır
        # (Store kayıtlarını yalnız kendi projesinde arar).
        target = store.project == project ? store : Store.new(root: store.root, project: project)
        segments = parsed[:segments]
        return render_project(target, project, json) if segments.empty?

        return render_refs(target, project, segments[1].to_s, json) if segments.first == "refs"

        type = segments.first.to_s.downcase
        return unknown_type(type) unless Store::TYPES.include?(type)

        return render_listing(target, project, type, json) if segments.length == 1

        id = segments[1..].join("/")
        record = target.get(type: type, id: id)
        return not_found(store, project, type, id) unless record

        json ? JSON.pretty_generate(record) : Render.entity(record, project: project)
      end

      def render_index(store, json)
        snapshot = store.index_snapshot
        json ? JSON.pretty_generate(snapshot) : Render.index(snapshot)
      end

      def render_project(store, project, json)
        summary = store.project_summary
        json ? JSON.pretty_generate(summary) : Render.project(project, summary)
      end

      def render_listing(store, project, type, json)
        summaries = store.list(type: type)
        return JSON.pretty_generate(summaries.map(&:to_h)) if json

        Render.listing(project: project, type: type, summaries: summaries.map(&:to_h),
                       uri_hint: "read_file rubik://storage/#{project}/#{type}/<id>",
                       refs: store.refs)
      end

      def render_refs(store, project, alias_name, json)
        resolved = store.refs[alias_name]
        unless resolved
          return Rubik::Tools::ToolOutput.error("Ref not found: '#{alias_name}' in project '#{project}'. " \
                                                "Known refs: #{store.refs.keys.sort.join(', ').strip.empty? ? '(none)' : store.refs.keys.sort.join(', ')}")
        end

        type = resolved.split(".").first
        record = store.get(type: type, id: resolved)
        return not_found(store, project, type, resolved) unless record

        json ? JSON.pretty_generate(record) : Render.entity(record, project: project)
      end

      def unavailable
        Rubik::Tools::ToolOutput.error("rubik://storage is not available: no store wired in this runtime " \
                                       "(config storage.enabled=false or standalone construction).")
      end

      def malformed(path)
        Rubik::Tools::ToolOutput.error("Malformed storage URI: #{path}. Forms: rubik://storage/index, " \
                                       "rubik://storage/<project>/<type>/<id>, rubik://storage/<project>/refs/<alias>.")
      end

      def malformed_refs
        Rubik::Tools::ToolOutput.error("Malformed refs URI: alias resolution needs a project — " \
                                       "rubik://storage/<project>/refs/<alias>.")
      end

      def unknown_type(type)
        Rubik::Tools::ToolOutput.error("Unknown entity type '#{type}' (valid: #{Store::TYPES.join(', ')}).")
      end

      def not_found(_store, project, type, id)
        Rubik::Tools::ToolOutput.error("Storage entity not found: #{project}/#{type}/#{id}. " \
                                       "List existing ids via read_file rubik://storage/#{project}/#{type}.")
      end
    end
  end
end
