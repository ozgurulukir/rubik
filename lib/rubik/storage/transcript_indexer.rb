# frozen_string_literal: true

require_relative "../uris"

module Rubik
  module Storage
    # Subagent tamamlanınca transcript'ı depoya indeksler (supervisor
    # handle_subagent_completion'dan tek satır çağrılır). Gövde = transcript
    # dosyasının ilk satırları (aramaya yeter); tam kopya zaten
    # rubik://subagent/<storage-id>/transcript üzerinden okunur. Başarısızlık
    # asla subagent akışını bozmaz — uyarı basılır (AGENTS.md §5: sessiz
    # yutma yok, yarım durum birikmez).
    module TranscriptIndexer
      module_function

      EXCERPT_LINES = 40

      def index(store, inst)
        return unless store && inst

        file = inst.transcript_uri.to_s
        # foreach: excerpt için tüm dosyayı belleğe almak yok (review bulgusu 3).
        excerpt = File.exist?(file) ? File.foreach(file).first(EXCERPT_LINES).join : "(transcript file unavailable)"
        # Gerçek upsert: alias üzerinden varsa mevcut id güncellenir — resume
        # sonrası ikinci tamamlanma yinelenen transcript varlığı yaratmaz.
        ref = Rubik::Uris.transcript_ref(inst.storage_id)
        existing = store.get(type: "transcript", id: ref)
        store.put(
          type: "transcript",
          title: "[#{inst.type_name}] #{inst.role} (#{inst.id}) — #{inst.state}",
          body: excerpt,
          tags: [inst.type_name.to_s, inst.state.to_s].uniq,
          links: { "subagent_id" => inst.storage_id.to_s, "transcript" => file },
          status: inst.state.to_s,
          id: existing&.[]("id"),
          ref: ref
        )
      rescue StandardError => e
        label = inst.respond_to?(:id) ? inst.id : inst.class
        warn "[Storage] transcript index failed for #{label}: #{e.class}: #{e.message}"
      end
    end
  end
end
