# frozen_string_literal: true

module Rubik
  # rubik:// sanal URI gramerinin TEK evi (uri-resolver-seam planı
  # 2026-10-01). Şemalar üç alanı kapsar (storage = FS-DB, subagent =
  # orchestrator yapısı, goal = canlı orchestrator anlık görüntüsü) —
  # dolayısıyla gramer storage'a ait değildir; bağımlılıksız yaprak olarak
  # burada yaşar (coeffects.rb/platform.rb öncülü). Desenler, çözümleyiciler
  # ve URI kurucuları yalnızca bu modüldedir; bekçi testi
  # (test_architectural_boundaries.rb) lib/ içinde başka rubik:// regexi
  # yasaklar. Buradaki desenler büyük/küçük harf duyarsızdır (\i) — mevcut
  # çağrı yüzeyleri hiçbir değişiklik olmadan aynen kalır.
  module Uris
    SCHEME = "rubik"
    STORAGE = "storage"
    GOAL = "goal"
    SUBAGENT = "subagent"

    # Desenler — lib/ içinde izin verilen TEK rubik:// regexleri.
    # Şema segmenti: [a-z][a-z0-9_-]* (çözümleme anahtarları küçük harfe
    # iner; scheme_of). Önek ya da URI sonunda olmalı; yarıda kesilmez.
    SCHEME_PREFIX = %r{\Arubik://([a-z][a-z0-9_-]*)}i
    STORAGE_PREFIX = %r{\Arubik://storage(?:/|\z)}i
    STORAGE_RELATIVE = %r{\Arubik://storage/(.*)\z}i
    GOAL_STATE = %r{\Arubik://goal(?:/state)?(?:\.xml)?\z}i
    # Yapılandırılmış Σ okuma yüzeyi (goal-ledger planı A): /state regexi
    # /ledger'ı EŞLEMEZ — iki ayrı gramer, tek adapter içinde iç dispatch.
    GOAL_LEDGER = %r{\Arubik://goal/ledger(?:\.xml)?\z}i
    SUBAGENT_TRANSCRIPT = %r{\Arubik://subagent/([^/]+)/transcript(?:\.jsonl)?(?:#.*)?\z}i

    # TranscriptIndexer ref sözleşimi: "subagent-<storage-id>".
    TRANSCRIPT_REF_PREFIX = "subagent-"

    module_function

    # -> "storage"|"goal"|"subagent"|... ya da nil (rubik:// değil).
    # to_s: nil/sembol girdiler dürüst nil düşer (NoMethodError yok).
    def scheme_of(uri)
      m = uri.to_s.match(SCHEME_PREFIX)
      m[1].downcase if m
    end

    # Kanonik soyma (uri_reader.rb'nin tarihsel biçimi): önek + ilk eğik
    # çizgi düşer. -> "uriproj/goal/1" | nil. Çıplak kök ("rubik://storage")
    # boş dize döndürür — UriReader bunu malformed olarak raporlar.
    def storage_path(uri)
      uri.sub(STORAGE_PREFIX, "") if STORAGE_PREFIX.match?(uri)
    end

    # Kozmetik görüntüleme soyması (show_file stub'ı, ui/renderer
    # kısaltması): zorunlu eğik çizgi, gerisi aynen. -> "proj/type/id" |
    # nil. Kanonik storage_path'ten FARKLIDIR (ör. "rubik://storage" çıplak
    # kökü soymaz) — yalnızca sunumda kullanılır, ayrıştırma için değil.
    def storage_relative(uri)
      m = uri.match(STORAGE_RELATIVE)
      m[1] if m
    end

    def storage_entity(project:, type:, id:)
      "#{SCHEME}://#{STORAGE}/#{project}/#{type}/#{id}"
    end

    def storage_project(project:)
      "#{SCHEME}://#{STORAGE}/#{project}"
    end

    def storage_ref(project:, ref:)
      "#{SCHEME}://#{STORAGE}/#{project}/refs/#{ref}"
    end

    def storage_listing(project:, type:)
      "#{SCHEME}://#{STORAGE}/#{project}/#{type}"
    end

    def storage_index
      "#{SCHEME}://#{STORAGE}/index"
    end

    def goal_state
      "#{SCHEME}://#{GOAL}/state"
    end

    def goal_ledger
      "#{SCHEME}://#{GOAL}/ledger"
    end

    def subagent_transcript(storage_id)
      "#{SCHEME}://#{SUBAGENT}/#{storage_id}/transcript"
    end

    # TranscriptIndexer ref sözleşimi: "subagent-<storage-id>". storage-id
    # kendisi zaten "subagent-" önekli doğar (ör. "subagent-1-12456-...") —
    # öneki körlemesine eklemek çift önekli, çözümlenemez alias üretiyordu
    # (js-tangram olay raporu 2026-10-04, olay #4). Önekli girdi aynen
    # kullanılır.
    def transcript_ref(storage_id)
      id = storage_id.to_s
      id.start_with?(TRANSCRIPT_REF_PREFIX) ? id : "#{TRANSCRIPT_REF_PREFIX}#{id}"
    end
  end
end
