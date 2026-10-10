# frozen_string_literal: true

require "json"
require_relative "../uris"

module Rubik
  module Storage
    # Subagent tamamlanınca transcript'ı depoya indeksler (supervisor
    # handle_subagent_completion'dan tek satır çağrılır). Gövde task +
    # final result merkezli deterministik kompozisyondur (2026-10-10
    # transcript sağlık paketi): system-prompt metni arama korpusuna HİÇ
    # girmez; sonuç metni aranabilir olur ("hangi subagent kırmızı
    # bildirdi?" sorusu görevle değil sonuçla bulunur). Tam kopya zaten
    # rubik://subagent/<storage-id>/transcript üzerinden okunur.
    # Başarısızlık asla subagent akışını bozmaz — uyarı basılır (AGENTS.md
    # §5: sessiz yutma yok, yarım durum birikmez).
    module TranscriptIndexer
      module_function

      # Gövde parçası başına üst sınır (~1-2KB): task ve result kendi
      # içinde kırpılır, fazlalık işaretlenir.
      PART_LIMIT = 1200

      def index(store, inst)
        return unless store && inst

        file = inst.transcript_uri.to_s
        # Gerçek upsert: alias üzerinden varsa mevcut id güncellenir — resume
        # sonrası ikinci tamamlanma yinelenen transcript varlığı yaratmaz.
        ref = Rubik::Uris.transcript_ref(inst.storage_id)
        existing = store.get(type: "transcript", id: ref)
        store.put(
          type: "transcript",
          title: "[#{inst.type_name}] #{inst.role} (#{inst.id}) — #{inst.state}",
          body: entity_body(inst, file),
          tags: [inst.type_name.to_s, inst.state.to_s].uniq,
          links: {
            "subagent_id" => inst.storage_id.to_s,
            # The raw path is forensics-only (read_file denies it): the
            # canonical read route rides in the entity itself so recall
            # consumers land on show_file in one hop (issue #97 finding 5).
            "canonical" => Rubik::Uris.subagent_transcript(inst.storage_id),
            "transcript" => file
          },
          status: inst.state.to_s,
          id: existing&.[]("id"),
          ref: ref
        )
      rescue StandardError => e
        label = inst.respond_to?(:id) ? inst.id : inst.class
        warn "[Storage] transcript index failed for #{label}: #{e.class}: #{e.message}"
      end

      # Task: transcript dosyasındaki İLK user satırı (seed'deki brif);
      # dosya yoksa inst.prompt'a düşer ve dürüst marker taşır. Result:
      # terminalde nil kalabilir (failed) — gövde yine kurulur, state
      # satırı düşer. System satırı bu kompozisyona asla girmez.
      def entity_body(inst, file)
        task = first_user_task(file)
        task_part = if task
                      "[task] #{clip(task)}"
                    elsif inst.respond_to?(:prompt)
                      "[task] #{clip(inst.prompt.to_s)} (transcript file unavailable)"
                    else
                      "[task] (transcript file unavailable)"
                    end

        result = inst.respond_to?(:result) ? inst.result.to_s : ""
        result_part = result.empty? ? "[state] #{inst.state} — no result recorded" : "[result] #{clip(result)}"
        "#{task_part}\n#{result_part}"
      end

      # foreach: task için tüm dosyayı belleğe almak yok; ilk user satırında
      # durur. UTF-8 kilitli okuma: transcript dosyaları UTF-8 yazılır;
      # işlem dış kodlaması (Windows TR yereli) başlık alıntısını bozmasın
      # (store.rb load_records ile aynı disiplin). Okuma/parse arızası
      # sessiz yutulmaz: uyarı basılır, inst.prompt fallback'i döner.
      def first_user_task(file)
        return nil unless File.exist?(file)

        File.foreach(file, encoding: "UTF-8") do |line|
          row = parse_row(line)
          next unless row.is_a?(Hash) && row["role"] == "user"

          content = row["content"].to_s
          return content unless content.empty?
        end
        nil
      rescue StandardError => e
        warn "[Storage] transcript task read failed for #{file}: #{e.class}: #{e.message}"
        nil
      end

      def parse_row(line)
        JSON.parse(line)
      rescue StandardError
        nil
      end

      def clip(text)
        text = text.to_s.scrub
        return text if text.length <= PART_LIMIT

        "#{text.slice(0, PART_LIMIT)}\n... [truncated #{text.length - PART_LIMIT} chars]"
      end
    end
  end
end
