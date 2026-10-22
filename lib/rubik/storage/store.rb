# frozen_string_literal: true

require "json"
require "digest"
require "monitor"
require "time"
require "fileutils"
require_relative "../platform"
require_relative "../uris"
require_relative "layout"
require_relative "folding"

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
      # BM25-lite (vakanüvis-v2 §4-V8): klasik Okapi değerleri — k1 terim
      # doygunluğu, b uzunluk normalizasyonu ağırlığı.
      BM25_K1 = 1.2
      BM25_B = 0.75
      # Alan kademeli bonus (issue #99 P3): BM25 birincil kalır; başlıkta
      # geçen sorgu terimi etikette geçene, o da yalnız gövdede geçene
      # üstünlük kurar. Terim başına birimdir ve tipik idf katkısının
      # altındadır — maddesel BM25 farklarını ezmez, sadece eşit-yakın
      # skorları alan bilgisiyle kırar.
      TITLE_TIER_BONUS = 1.0
      TAGS_TIER_BONUS = 0.5

      Summary = Struct.new(:id, :row, :title, :status, :updated_at, :tags, keyword_init: true)

      attr_reader :root, :project

      def initialize(project:, root: Layout.storage_root)
        @root = File.expand_path(root.to_s)
        @project = Layout.slugify(project)
        @monitor = Monitor.new
        # Parse cache (vakanuvis-v2 §4-V8): tip => {mtime:, records:}. mtime
        # doğrulaması hem yazı sonrası tazeliği hem dış müdahaleyi kapatır.
        # Dönen dizi PAYLAŞILIR ve FROZEN (arch-deepening 2026-10-08 #10):
        # dondurma cache dolumunda yapılır — "arayan mutasyon yapmaz" sözü
        # artık yorum değil, FrozenError (put/list zaten kopya üzerinde
        # çalışır).
        @records_cache = {}
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
          resolve_types(type).flat_map { |t| load_records(t) }
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
        tokens = Folding.fold(query).split
        return [] if tokens.empty?

        @monitor.synchronize do
          matched = resolve_types(type).flat_map do |t|
            records = load_records(t)
            haystacks = haystacks_for(t, records)
            records.each_index.select { |i| tokens.all? { |token| haystacks[i].include?(token) } }
                   .map { |i| records[i] }
          end
          matched.sort_by { |r| [r["type"].to_s, r["row"].to_i] }
        end
      end

      # BM25-lite ilgi sıralaması (vakanuvis-v2 §4-V8, Aşama 1): aday üretim
      # search ile AYNI token-AND eşiğidir; eşleşenler Okapi skoruna göre
      # sıralanır. Ek maliyet disiplini: df TEK include? geçişinden (AND
      # filtresinin kendisinden) gelir, uzunluk normalizasyonu bytesize (O(1))
      # üzerinden, tf yalnız eşleşen kayıtlarda scan edilir. Eşitlik bozma
      # updated_at desc → [type,row] ⇒ aynı depo ⇒ aynı sıra (replay/pin).
      # Alan kademeli bonus (issue #99 P3): skora terim başına +1.0 başlık
      # / +0.5 etiket izi eklenir — BM25 birincil kalmaya devam eder, bonus
      # yalnız alan-tierini kırar (belgelenmiş sözleşme değişikliği).
      # `search`'ün [type,row] sözleşmesi bilinçli olarak değişmez —
      # sıralama politikası yalnız recall sunum katmanının talebidir.
      # require_all (issue #99 P2): false iken aday eşiği OR'a gevşer
      # (herhangi bir terimi taşıyan kayıt) — fallback recall içindir;
      # skorlama iki ducte de aynıdır, default davranış birebir korunur.
      def search_ranked(query:, type: nil, require_all: true)
        tokens = Folding.fold(query).split
        return [] if tokens.empty?

        @monitor.synchronize do
          corpus = resolve_types(type).filter_map do |t|
            records = load_records(t)
            next if records.empty?

            haystacks = haystacks_for(t, records)
            folded_fields = folded_fields_for(t, records)
            { records: records, haystacks: haystacks, folded_fields: folded_fields,
              has: tokens.map { |token| haystacks.map { |h| h.include?(token) } } }
          end
          return [] if corpus.empty?

          total = corpus.sum { |c| c[:records].size }
          avgdl = corpus.sum { |c| c[:haystacks].sum(&:bytesize) }.fdiv(total)
          dfs = tokens.each_index.map { |ti| corpus.sum { |c| c[:has][ti].count(true) } }

          gate = ranked_gate(require_all)
          scored = corpus.flat_map do |c|
            c[:records].each_index.select { |i| gate.call(c[:has], i) }.map do |i|
              score = tokens.each_with_index.sum do |token, ti|
                df = dfs[ti]
                next 0.0 if df.zero?

                # PERF: count_occurrences using String#index avoids Array allocation of String#scan
                tf = count_occurrences(c[:haystacks][i], token)
                next 0.0 if tf.zero?

                idf = Math.log(((total - df + 0.5) / (df + 0.5)) + 1)
                dl = c[:haystacks][i].bytesize
                idf * (tf * (BM25_K1 + 1)) / (tf + (BM25_K1 * (1 - BM25_B + (BM25_B * dl / avgdl))))
              end
              # PERF: pass cached folded title and tags to avoid String folding & array join allocations per score
              f_title, f_tags = c[:folded_fields][i]
              [score + field_tier_bonus(tokens, f_title, f_tags), c[:records][i]]
            end
          end
          ordered = scored.sort do |(score_a, rec_a), (score_b, rec_b)|
            (score_b <=> score_a).nonzero? ||
              (rec_b["updated_at"].to_s <=> rec_a["updated_at"].to_s).nonzero? ||
              (rec_a["type"].to_s <=> rec_b["type"].to_s).nonzero? ||
              (rec_a["row"].to_i <=> rec_b["row"].to_i)
          end
          ordered.map { |_score, record| record }
        end
      end

      # Aday eşiği: require_all (AND — default, recall) ya da OR
      # gevşetmesi (fallback — issue #99 P2).
      def ranked_gate(require_all)
        if require_all
          ->(has, i) { has.all? { |row| row[i] } }
        else
          ->(has, i) { has.any? { |row| row[i] } }
        end
      end

      # PERF: Zero-allocation string occurrence counting via String#index loop.
      # Replaces String#scan(token).size to avoid array allocation per matched term.
      def count_occurrences(haystack, token)
        return 0 if token.empty?

        count = 0
        offset = 0
        token_len = token.length
        while (idx = haystack.index(token, offset))
          count += 1
          offset = idx + token_len
        end
        count
      end

      # Terim başına alan izi: katlanmış başlıkta geçen terim +1.0,
      # yalnız katlanmış etiketlerde geçen +0.5, gövde izi 0 — bkz.
      # TITLE_TIER_BONUS/TAGS_TIER_BONUS. Yalnız AND eşiğini geçen
      # kayıtlar için hesaplanır (ek tarama yok).
      # PERF: accepts pre-folded title & tags strings or fallback record for backward compatibility.
      def field_tier_bonus(tokens, title_or_record, tags = nil)
        if tags.nil? && title_or_record.is_a?(Hash)
          title = Folding.fold(title_or_record["title"])
          tags = Folding.fold(Array(title_or_record["tags"]).join("\n"))
        else
          title = title_or_record.to_s
          tags = tags.to_s
        end

        sum = 0.0
        tokens.each do |token|
          if title.include?(token)
            sum += TITLE_TIER_BONUS
          elsif tags.include?(token)
            sum += TAGS_TIER_BONUS
          end
        end
        sum
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

        # tip.satır formları alias'tan ÖNCE denir; kronikçi alias'ları bu
        # şekle asla düşmez — tek Garantör: Vakanuvis::Vocabulary
        # (rakam koruması, slug mint'inde).
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

      # Yazım sınırında başarısız-hızlı (issue #100 P1): boolean/sayılar
      # sessizce "false"/"42" dizgelerine dönüşerek etiketi çöpüne
      # çeviriyordu — coercion yok, ret var. Mesaj ne geldiğini ve nasıl
      # düzeltileceğini söyler.
      def normalize_tags(tags)
        list = Array(tags)
        list.each do |tag|
          next if tag.is_a?(String)

          raise ArgumentError,
                "tags must be strings — got #{tag.class} (#{tag.inspect}). " \
                "Stringify the value before put, or pass an array of strings."
        end
        list.reject { |t| t.strip.empty? }.uniq.sort
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

      # nil => tüm tipler; String => tek tip; Array => çoklu tip (vakanuvis-v2
      # §4-V8: recall artık memory+wiki ikilisini TEK aramada ister — 7 tipin
      # tamamını parse etmekten kurtulur).
      # Arama samanlığı (title+body+tags, Folding.fold — TR I-sınıfı dahil
      # tek katlama kuralı, folding.rb): parse cache girdisinde tembel
      # memoize edilir — sorgu başına 1 MB'lık dizgi kurulumu tekrarlamaz.
      # Kayıt kümesi paylaşımlı olduğundan samanlıklar da dondurulmuş
      # paylaşılır (include?/scan/bytesize mutasyon yapmaz).
      def haystacks_for(type, records)
        entry = @records_cache[type]
        return records.map { |r| haystack_of(r) } unless entry

        entry[:haystacks] ||= records.map { |r| haystack_of(r) }.freeze
      end

      # PERF: Memoize folded title and tags per record in @records_cache
      # to avoid re-folding and array joining on every search_ranked query.
      def folded_fields_for(type, records)
        entry = @records_cache[type]
        unless entry
          return records.map do |r|
            [Folding.fold(r["title"]), Folding.fold(Array(r["tags"]).join("\n"))]
          end
        end

        entry[:folded_fields] ||= records.map do |r|
          [Folding.fold(r["title"]), Folding.fold(Array(r["tags"]).join("\n"))].freeze
        end.freeze
      end

      def haystack_of(record)
        Folding.fold("#{record['title']}\n#{record['body']}\n#{Array(record['tags']).join("\n")}")
      end

      def resolve_types(type)
        return TYPES.dup if type.nil?

        Array(type).map { |t| t.to_s.downcase }.select { |t| TYPES.include?(t) }
      end

      def load_records(type)
        path = Layout.entities_path(project_dir, type)
        return [] unless File.exist?(path)

        mtime = File.mtime(path)
        cached = @records_cache[type]
        return cached[:records] if cached && cached[:mtime] == mtime

        # Depo dosyaları her zaman UTF-8 yazılır (safe_json_generate + "wb");
        # okuma da işlem dış kodlamasına değil UTF-8'a kilitlenir —
        # UTF-8 olmayan Windows yerelinde (TR: cp1254/cp857) yanlış etiketli
        # dizgiler ASCII olmayan recall sorgularında CompatibilityError
        # üretiyordu. Scrub bozuk baytı U+FFFD'ye düşürür, satırı düşürmez.
        # Bozuk/Hash-olmayan satır atlanır ve SAYILIR (review: sessiz
        # kısmi-okuma gözlemlenebilir olsun); Hash olmayan JSON değeri
        # (elle düzenleme: "42", ["x"]) tüm tipi zehirlemesin.
        skipped = 0
        records = File.foreach(path, encoding: "UTF-8").filter_map do |line|
          line.strip!
          next if line.empty?

          parsed = begin
            JSON.parse(line.valid_encoding? ? line : line.scrub)
          rescue JSON::ParserError
            nil
          end
          if parsed.is_a?(Hash)
            parsed
          else
            skipped += 1
            nil
          end
        end
        Rubik::Log.warn(:storage, "#{path}: skipped #{skipped} malformed row(s)") if skipped.positive?
        # Paylaşılan cache girdisi dondurulur: dizi + her kayıt hash'i +
        # kayıtların iç koleksiyonları (tags/links — shallow freeze yeterli
        # değildi, en çok uzatılan alanlar sessiz bozulabilirdi).
        # Haystack'ler ilk memoize'da donar (haystacks_for). Paylaşım
        # korunur; kazara mutasyon fail-loud olur.
        records.freeze
        records.each do |record|
          record.each_value { |v| v.freeze if v.is_a?(Array) || v.is_a?(Hash) }
          record.freeze
        end
        @records_cache[type] = { mtime: mtime, records: records }
        records
      rescue Errno::ENOENT
        []
      end

      def write_records(type, records)
        @records_cache.delete(type) # mtime da yenilenir; çifte güvence
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
