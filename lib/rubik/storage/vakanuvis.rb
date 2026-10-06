# frozen_string_literal: true

module Rubik
  module Storage
    # Vakanüvis — arka plan kronikçisi (plan 2026-10-04, kararlar K1-K9).
    # Saray kronikcisi metaforu: maestro'nun (padişah) turn'ünü ASLA
    # uyarmaz (re-uyandırma kümesinin tamamen dışında; yalnız dmesg/stderr),
    # olay sınırlarında deterministik annal yazar (Düzlem 1, LLM'siz),
    # gerektiğinde sınırlı otonomlu damıtıcı subagent doğurur (Düzlem 2,
    # LLM'li — öneri üretir, yazmayı daima Düzlem 1 yapar).
    #
    #   ref grammar : annal.session.<slug> / annal.goal.<n>  (note tipi)
    #                mem.<topic-slug>                        (memory tipi)
    #                wiki.home / wiki.<slug>                 (wiki tipi)
    #   konfig     : subagents.vakanuvis.* (operatör-only; K1 defaults ON)
    #
    # Determinizm garantileri (§4.2): kararlarda duvar saati YOK (sadece
    # olay sırası), sabit ref grammar, her yazım ref-bazlı gerçek upsert
    # (içerik hash'i değişmediyse put atlanır — version sabit), tek worker
    # + FIFO kuyruk, taşmada drop-oldest + warn.
    module Vakanuvis
      SLUG_MAX = 40

      module_function

      # Deterministik slug: aynı metin ⇒ aynı slug ⇒ aynı ref (digest
      # makbuzlarının ve mem./wiki. ref'lerin yeniden oynatılabilirliği
      # buna dayanır). Yalnızca-rakam slug'a "n" öneki zorunlu: Store'un
      # çözümleyicisi "wiki.42" gibi iki parçalı tip.satır formlarını ref
      # alias'tan ÖNCE dener — çarpışma yanlış satırı ezmesi demekti.
      def slugify(text)
        slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug = slug[0, SLUG_MAX].to_s.gsub(/\A-+|-+\z/, "")
        slug = "n#{slug}" if slug.match?(/\A\d+\z/)
        slug.empty? ? "untitled" : slug
      end

      # Ref-bazlı GERÇEK upsert (Store'da ref ile ikinci put yeni satır
      # açtığı için — store.rb §2.3 bulgusu): ref üzerinden mevcut kaydı
      # bulur; içerik değişmediyse DOKUNMAZ (version/updated_at sabit —
      # replay idempotent), değiştiyse AYNI id ile günceller (refs/linkler
      # kopmaz). Dönen kayda "skipped" tanıklığı eklenir.
      def upsert(store, type:, ref:, title:, body: "", tags: [], links: {}, status: "active")
        existing = store.get(type: type, id: ref)
        return existing.merge("skipped" => true) if existing && content_unchanged?(existing, title, body, tags, links, status)

        store.put(type: type, title: title, body: body, tags: tags, links: links,
                  status: status, id: existing&.[]("id"), ref: ref)
             .merge("skipped" => false)
      end

      # K2 supersede: iz bırak — status "superseded" + superseded_by
      # link'i (halefi kim: yeni kayıt id'si ya da "forget").
      def supersede_record(store, record, by:)
        links = record["links"].to_h.merge("superseded_by" => by.to_s)
        store.put(type: record["type"], title: record["title"], body: record["body"],
                  tags: record["tags"], links: links, status: "superseded", id: record["id"])
      end

      # Vakanüvis'in kendi dmesg etiketi (K6): sessizlik sözleşmesi
      # gereği notice YOK — sadece dmesg/stderr düzlemi.
      SUBSYSTEM = :storage

      def log_via(dmesg, level, message)
        dmesg.respond_to?(:log) ? dmesg.log(SUBSYSTEM, level, message) : Rubik::Log.send(level, SUBSYSTEM, message)
      rescue StandardError
        Rubik::Log.warn(SUBSYSTEM, message)
      end

      def content_unchanged?(existing, title, body, tags, links, status)
        existing["title"] == title.to_s &&
          existing["body"] == body.to_s &&
          existing["tags"] == Array(tags).map(&:to_s).reject { |t| t.strip.empty? }.uniq.sort &&
          existing["links"] == links.to_h { |k, v| [k.to_s, v.to_s] }.sort.to_h &&
          existing["status"] == status.to_s
      end
    end
  end
end

require_relative "vakanuvis/annal_writer"
require_relative "vakanuvis/memory_steward"
require_relative "vakanuvis/wiki_skeleton"
require_relative "vakanuvis/distill_gate"
require_relative "vakanuvis/harness"
require_relative "vakanuvis/service"
