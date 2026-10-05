# frozen_string_literal: true

require "json"
require "digest"
require "monitor"
require "time"
require "fileutils"
require_relative "../platform"
require_relative "../uris"
require_relative "layout"

module Rubik
  module Storage
    # Merkezi sanal FS-DB deposu: rubik://storage/<project>/<type>/<id>
    # adreslenebilir varlıklar (goal/plan/memory/wiki/transcript/review/note).
    #
    #   id      => "plan.3.9f86d081884c7d21" — tip + satır (row) + OLUŞTURMA
    #              anındaki içerik karmasının ilk 16 hexasi. Güncelleme id'yi
    #              korur (refs/linkler kopmaz), "hash" alanı güncel içeriği
    #              izler; row asla yeniden kullanılmaz.
    #   fiziki  => <root>/<project>/store/{meta.json,<type>.jsonl}
    #   indeks  => <root>/index.json (merkezi; proje sayıları + zaman damgaları)
    #
    # Tek kullanıcı CLI ölçeği: süreç içi Monitor ile thread-güvenli; çapraz
    # süreç yazımlarında meta/index last-writer-wins (belgelenmiş sınırlama).
    # Yazmalar Platform.atomic_write ile tmp+rename; kurulum tembeldir —
    # ilk mutasyona kadar hiçbir dizin oluşturulmaz (standalone/test
    # kurulumu dosya sistemine dokunmaz).
    class Store
      TYPES = ["goal", "plan", "memory", "wiki", "transcript", "review", "note"].freeze
      ID_PATTERN = /\A([a-z]+)\.(\d+)\.([0-9a-f]{16})\z/
      HASH_PREFIX_MIN = 8
      REF_PATTERN = /\A[a-zA-Z0-9._-]+\z/

      Summary = Struct.new(:id, :row, :title, :status, :updated_at, :tags, keyword_init: true)

      attr_reader :root, :project

      def initialize(project:, root: Layout.storage_root)
        @root = File.expand_path(root.to_s)
        @project = Layout.slugify(project)
        @monitor = Monitor.new
      end

      def project_dir
        Layout.project_dir(@root, @project)
      end

      def uri_for(type, id)
        Rubik::Uris.storage_entity(project: @project, type: type, id: id)
      end

      # Oluşturur veya günceller. id verilirse o kayıt (satır adresli)
      # güncellenir — version artar, hash yeniden hesaplanır, id sabit kalır.
      # ref verilirse alias o kaydın id'sine bağlanır.
      def put(type:, title:, body: "", tags: [], links: {}, status: "active", id: nil, ref: nil)
        type = type.to_s.downcase
        raise ArgumentError, "unknown entity type '#{type}' (valid: #{TYPES.join(', ')})" unless TYPES.include?(type)
        raise ArgumentError, "title is required" if title.to_s.strip.empty?

        now = Time.now.utc.iso8601
        @monitor.synchronize do
          meta = load_meta
          records = load_records(type)
          existing = id && resolve_record(records, id.to_s, meta)
          raise ArgumentError, "entity '#{id}' not found in #{type}" if id && !existing

          record =
            if existing
              existing.merge(
                "title" => title.to_s, "body" => body.to_s, "tags" => normalize_tags(tags),
                "links" => normalize_links(links), "status" => status.to_s,
                "hash" => content_hash(type, title, body, tags, links),
                "version" => existing["version"].to_i + 1, "updated_at" => now
              )
            else
              row = meta_next_row(meta, type)
              hash = content_hash(type, title, body, tags, links)
              { "id" => "#{type}.#{row}.#{hash[0, 16]}", "type" => type, "project" => @project,
                "row" => row, "hash" => hash, "title" => title.to_s, "body" => body.to_s,
                "tags" => normalize_tags(tags), "links" => normalize_links(links),
                "status" => status.to_s, "version" => 1, "created_at" => now, "updated_at" => now }
            end

          records = records.reject { |r| r["row"] == record["row"] } << record
          ensure_project_dirs
          write_records(type, records.sort_by { |r| r["row"].to_i })
          meta_bump_counts(meta, type) unless existing
          meta_set_ref(meta, ref, record["id"]) if ref
          save_meta(meta)
          touch_index(meta)
          record.dup
        end
      end

      # Çözüm sırası: tam id ("plan.3.<hash16>") → "plan.3" (tip.satır) →
      # salt satır ("3") → karma öneki (>= 8 hex) → alias (refs). Bulunamazsa
      # nil — dürüst not-found arayan katmanda.
      def get(type:, id:)
        type = type.to_s.downcase
        return nil unless TYPES.include?(type)

        @monitor.synchronize do
          resolve_record(load_records(type), id.to_s, load_meta)
        end
      end

      def list(type: nil)
        @monitor.synchronize do
          types = type ? [type.to_s.downcase] : TYPES
          types.select { |t| TYPES.include?(t) }.flat_map { |t| load_records(t) }
               .sort_by { |r| [r["type"].to_s, r["row"].to_i] }
               .map { |r| summary_of(r) }
        end
      end

      def search(query:, type: nil)
        # Token-AND: her boşlukla ayrılmış terim, kaydın title/body/tags
        # alanlarından en az birinde geçmeli. Tüm sorgu tek substring olarak
        # arandığında "ratelimit-lock regression 11/11" gibi doğal çok
        # kelimeli sorgular kelimesi kelimesine eşleşmediği için 0 sonuç
        # dönüyordu (js-tangram olay raporu 2026-10-04, olay #2 — "indeks
        # bayatlığı" değil, eşleştirme semantiğiydi). Tek terimli sorgular
        # eski davranışın birebir aynısı.
        tokens = query.to_s.downcase.split
        return [] if tokens.empty?

        @monitor.synchronize do
          types = type ? [type.to_s.downcase] : TYPES
          records = types.select { |t| TYPES.include?(t) }.flat_map { |t| load_records(t) }
          matched = records.select do |r|
            haystack = "#{r['title']}\n#{r['body']}\n#{Array(r['tags']).join("\n")}".downcase
            tokens.all? { |token| haystack.include?(token) }
          end
          matched.sort_by { |r| [r["type"].to_s, r["row"].to_i] }
        end
      end

      def set_ref(name, id)
        name = name.to_s
        raise ArgumentError, "invalid ref name '#{name}'" unless name.match?(REF_PATTERN)

        @monitor.synchronize do
          meta = load_meta
          target = TYPES.lazy.map { |t| resolve_record(load_records(t), id.to_s, meta) }
                        .find(&:itself)
          raise ArgumentError, "entity '#{id}' not found in any type" unless target

          meta_set_ref(meta, name, target["id"])
          ensure_project_dirs
          save_meta(meta)
          { "ref" => name, "id" => target["id"], "uri" => uri_for(target["type"], target["id"]) }
        end
      end

      def refs
        @monitor.synchronize do
          load_meta.fetch("refs", {}).dup
        end
      end

      def delete(type:, id:)
        type = type.to_s.downcase
        return nil unless TYPES.include?(type)

        @monitor.synchronize do
          meta = load_meta
          records = load_records(type)
          target = resolve_record(records, id.to_s, meta)
          return nil unless target

          write_records(type, records.reject { |r| r["row"] == target["row"] })
          meta["counts"] = (meta["counts"] || {}).then { |c| c.merge(type => [c[type].to_i - 1, 0].max) }
          meta["refs"] = meta.fetch("refs", {}).reject { |_k, v| v == target["id"] }
          save_meta(meta)
          touch_index(meta)
          target
        end
      end

      # Proje özeti: tip başına sayı + son yazım zamanı.
      def project_summary
        @monitor.synchronize do
          meta = load_meta
          { "project" => @project, "path" => project_dir,
            "entity_counts" => meta.fetch("counts", {}).dup,
            "created_at" => meta["created_at"], "updated_at" => meta["updated_at"],
            "refs" => meta.fetch("refs", {}).dup }
        end
      end

      # Merkezi indeks anlık görüntüsü (sınıf metodu — kök altındaki tüm
      # projeler). Disk okunur; eksikse boş iskelet.
      def self.index_snapshot(root)
        path = Layout.index_path(File.expand_path(root.to_s))
        return { "version" => 1, "updated_at" => nil, "projects" => {} } unless File.exist?(path)

        raw = JSON.parse(File.read(path, encoding: "UTF-8").scrub)
        raw.merge("projects" => raw.fetch("projects", {}))
      rescue JSON::ParserError, Errno::ENOENT
        { "version" => 1, "updated_at" => nil, "projects" => {} }
      end

      def index_snapshot
        self.class.index_snapshot(@root)
      end

      private

      def summary_of(record)
        Summary.new(id: record["id"], row: record["row"].to_i, title: record["title"].to_s,
                    status: record["status"].to_s, updated_at: record["updated_at"].to_s,
                    tags: Array(record["tags"]).dup)
      end

      def resolve_record(records, selector, meta)
        selector = selector.to_s.strip
        return nil if selector.empty?

        # Tam id içerik adreslemesidir: birebir eşleşme (bayat hash → not
        # found; satır kısa formu ayrı dalda ele alınır).
        return records.find { |r| r["id"] == selector } if selector.match?(ID_PATTERN)

        if (m = selector.match(/\A([a-z]+)\.(\d+)\z/))
          type = m[1]
          row = m[2].to_i
          return records.find { |r| r["type"] == type && r["row"] == row }
        end
        return records.find { |r| r["row"].to_s == selector } if selector.match?(/\A\d+\z/)
        return records.find { |r| r["hash"].to_s.start_with?(selector.downcase) } if selector.match?(/\A[0-9a-f]{#{HASH_PREFIX_MIN},64}\z/i)

        # Son şans: alias — refs üzerinden tek sekme. Eski depolarda
        # transcript alias'ı ÇİFT önekle basılmıştı ("subagent-subagent-..."):
        # doğal form ("subagent-1-...") gelirse öneki ekleyip bir kez daha
        # bakarız — böylece completion-time transcript upsert'i eski satırı
        # bulur, kopya varlık açılmaz (uris.rb transcript_ref düzeltmesiyle
        # birlikte; js-tangram olay raporu 2026-10-04, olay #4).
        refs = meta.fetch("refs", {})
        resolved_id = refs[selector]
        resolved_id = refs["#{Rubik::Uris::TRANSCRIPT_REF_PREFIX}#{selector}"] if resolved_id.nil? && selector.start_with?(Rubik::Uris::TRANSCRIPT_REF_PREFIX)
        resolved_id ? records.find { |r| r["id"] == resolved_id } : nil
      end

      def content_hash(type, title, body, tags, links)
        canonical = {
          "type" => type.to_s, "title" => title.to_s, "body" => body.to_s,
          "tags" => normalize_tags(tags), "links" => normalize_links(links)
        }
        Digest::SHA256.hexdigest(Rubik::Platform.safe_json_generate(canonical))
      end

      def normalize_tags(tags)
        Array(tags).map(&:to_s).reject { |t| t.strip.empty? }.uniq.sort
      end

      def normalize_links(links)
        links.to_h { |k, v| [k.to_s, v.to_s] }.sort.to_h
      end

      def meta_next_row(meta, type)
        rows = (meta["next_row"] ||= {})
        rows[type] = rows[type].to_i + 1
        meta["updated_at"] = Time.now.utc.iso8601
        rows[type]
      end

      def meta_bump_counts(meta, type)
        counts = (meta["counts"] ||= {})
        counts[type] = counts[type].to_i + 1
      end

      def meta_set_ref(meta, name, id)
        refs = (meta["refs"] ||= {})
        refs[name] = id
        meta["updated_at"] = Time.now.utc.iso8601
      end

      def ensure_project_dirs
        FileUtils.mkdir_p(Layout.store_dir(project_dir))
      end

      def load_meta
        path = Layout.meta_path(project_dir)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path, encoding: "UTF-8").scrub)
      rescue JSON::ParserError, Errno::ENOENT
        {}
      end

      def save_meta(meta)
        meta["created_at"] ||= Time.now.utc.iso8601
        Rubik::Platform.atomic_write(Layout.meta_path(project_dir),
                                     JSON.pretty_generate(meta))
      end

      def load_records(type)
        path = Layout.entities_path(project_dir, type)
        return [] unless File.exist?(path)

        # Depo dosyaları her zaman UTF-8 yazılır (safe_json_generate + "wb");
        # okuma da işlem dış kodlamasına değil UTF-8'a kilitlenir —
        # UTF-8 olmayan Windows yerelinde (TR: cp1254/cp857) yanlış etiketli
        # dizgiler ASCII olmayan recall sorgularında CompatibilityError
        # üretiyordu. Scrub bozuk baytı U+FFFD'ye düşürür, satırı düşürmez.
        File.foreach(path, encoding: "UTF-8").filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line.scrub)
        rescue JSON::ParserError
          nil # Bozuk satır atlanır — yarım dosya tüm okumayı düşürmesin.
        end
      rescue Errno::ENOENT
        []
      end

      def write_records(type, records)
        body = records.map { |r| Rubik::Platform.safe_json_generate(r) }.join("\n")
        body += "\n" unless body.empty?
        Rubik::Platform.atomic_write(Layout.entities_path(project_dir, type), body)
      end

      # Merkezi indeksi günceller: bu projenin girdisi canlı meta'dan
      # yeniden yazılır, diğer projelerin girdileri korunur.
      def touch_index(meta)
        snapshot = self.class.index_snapshot(@root)
        snapshot["projects"][@project] = {
          "path" => project_dir,
          "entity_counts" => meta.fetch("counts", {}).dup,
          "created_at" => (snapshot["projects"][@project] || {})["created_at"] || meta["created_at"],
          "updated_at" => meta["updated_at"]
        }
        snapshot["updated_at"] = meta["updated_at"]
        Rubik::Platform.atomic_write(Layout.index_path(@root), JSON.pretty_generate(snapshot))
      end
    end
  end
end
