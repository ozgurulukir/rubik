# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Düzlem 2'nin durumlu yarısı: digest iş kuyruğu, doğum sicili ve
      # kirli işaret — DistillGate kurallarının (doğrulayıcı, brif,
      # makbuz) biriktirici Ω'su. ctx servisi DEĞİLDİR, kendi thread'i
      # YOKTUR (worker Harness'te kalır); ömrü sahibi Harness'in ömrüdür
      # (kompozisyon) — o yüzden ctx.on_dispose tersi gerekmez.
      #
      # Tek kilit (@lock) kuyruk + sicil + kirli işareti SAHİPLENİR ve
      # kilit sıralaması kendiliğinden tekyönlüdür: @lock altında yalnız
      # store/supervisor çağrılır (store monitoru asla geri çağırmadığı
      # için @lock → store TEK yuvalanmadır); Harness'in @monitor'u @lock
      # altında ASLA alınmaz. Eski with_gate → @monitor dansı silindi,
      # taşınmadı — gate durumu ile harness durumu artık aynı kod yolunu
      # paylaşmaz.
      module DistillGate
        # Doğum kapısı + iş defteri. Kurucu enjeksiyonuyla çalışır: store,
        # supervisor, event_bus ve sözlü girdiler dışarıdan verilir —
        # Harness'e ASLA geri dokunmaz.
        class Gate
          attr_reader :store, :supervisor, :dmesg, :session_slug, :max_steps, :model

          def initialize(store:, max_steps:, session_slug:, supervisor: nil, dmesg: nil,
                         event_bus: nil, enabled: true, model: nil)
            @store = store
            @supervisor = supervisor
            @dmesg = dmesg
            @event_bus = event_bus
            @enabled = enabled
            @max_steps = max_steps
            @model = model
            @session_slug = session_slug
            @pending_digests = []
            @distillers = {}
            @lock = Mutex.new
            # v2 §4-V5: kirli işareti — son başarılı derlemeden bu yana KALICI
            # içerik (memory+wiki+note içerik ayak izi) değişmediyse toplu
            # damıtıcı doğmaz. Turn satırları ayak izini değiştirmez: saf
            # turn akışında derleme boşa yakılmaz.
            @compile_footprint = nil
          end

          # ---- Seam 1: maestro tool thread'i (Harness#digest delege eder) --

          # Hedef için dedupe denetimi + itme TEK @lock kritik bölümünde;
          # hemen ardından doğum denemesi AYRI bir @lock penceresinde
          # (iki fazlı — tek büyük kritik bölüm İÇİNE ALMA). Doğum
          # başarısızsa iş kuyrukta kalır: yarım durum birikmez.
          # Dönen makbuz dizgesi bayt-bayt eski Harness#digest çıktısıdır.
          def submit(query)
            target = Vocabulary.wiki_ref(query)
            # v2 §4-V5: aynı hedefli iş zaten kuyrukta ya da uçuştaysa makbuz
            # 'already queued' varyantına düşer — çift doğum yok.
            in_flight = @lock.synchronize do
              busy = @pending_digests.any? { |j| j[:target] == target } ||
                     @distillers.any? { |_id, j| j[:target] == target }
              unless busy
                @pending_digests << { query: query, target: target,
                                      transcript_uris: source_transcript_uris }
              end
              busy
            end
            if in_flight
              return "Digest already queued for '#{target}' (#{AnnalWriter.one_line(query, 60)}): the chronicler is " \
                     "compiling it — recall it later with vakanuvis(action: 'recall', query: '...')."
            end

            spawned = spawn_job!(batch: false)
            DistillGate.receipt(query: query, target: target, spawned: !spawned.nil?)
          end

          # ---- Seam 2: worker thread'i (Harness#handle_subagent çağırır) ---

          # Ham subagent tamamlanma olayı. İş sicilden @lock altında
          # silinir, KİLİT BIRAKILIR, sonra supervisor.get + hasat TEK
          # kurtarma bölgesinde koşar: get/inst.result (hedeflenmemiş
          # double, kayıp kayıt) ve DistillGate.harvest (disk hatası, bozuk
          # satır) raise ederse iş kaybolmaz — hedefli iş kuyruğa geri
          # konur (review: sessiz-yutma sınıfı), toplu iş dürüstçe düşer.
          # Dönen değer: :compiled | :incomplete | :crashed | :rejected | nil.
          def completion_event(payload)
            job = @lock.synchronize { @distillers.delete(payload[:id].to_s) }
            return unless job

            outcome = begin
              inst = @supervisor.respond_to?(:get) ? @supervisor.get(payload[:id].to_s) : nil
              finish_body = inst.respond_to?(:result) ? inst.result : nil
              if payload[:state].to_s != "completed" || finish_body.nil?
                :incomplete
              else
                DistillGate.harvest(self, job, finish_body)
              end
            rescue StandardError => e
              if job[:target]
                @lock.synchronize { @pending_digests << job }
                Vakanuvis.log_via(@dmesg, :warn,
                                  "harvest crashed for #{job[:target]} (#{e.class}: #{e.message}) — digest requeued")
              else
                Vakanuvis.log_via(@dmesg, :warn,
                                  "harvest crashed for batch compile (#{e.class}: #{e.message}) — compile dropped")
              end
              :crashed
            end

            case outcome
            when :compiled
              Vakanuvis.log_via(@dmesg, :info, "distiller compiled #{job[:target] || 'a wiki page'}")
            when :incomplete
              if job[:target]
                @lock.synchronize { @pending_digests << job }
                Vakanuvis.log_via(@dmesg, :warn,
                                  "distiller for #{job[:target]} ended state=#{payload[:state]} — digest requeued")
              else
                Vakanuvis.log_via(@dmesg, :warn, "batch distiller ended state=#{payload[:state]} — compile dropped")
              end
            when :crashed, :rejected then nil # kendi dalında detay loglandı (crash requeue/drop; B6 ret sebebi + trim)
            else
              # Beklenmedik outcome — yanlış "schema ret" etiketi yerine
              # gerçek değeri yaz (future harvest sembolleri sessiz kalmasın).
              Vakanuvis.log_via(@dmesg, :warn, "distiller ended with unexpected outcome=#{outcome.inspect} — dropped, store untouched")
            end
            outcome
          end

          # ---- Seam 3: worker thread'inin flush noktası (Harness#maintain) --

          # Toplu doğum kararı, kirli işarete bağlıdır (v2 §4-V5): kalıcı
          # içerik değişmediyse damıtıcı yakılmaz.
          def flush_tick
            spawn_job!(batch: true) if dirty?
          end

          # Salt-okunuma peeki (test/kurcalama yüzeyi): kuyruğun başını
          # gösterir — tüketmez. Üretim görünürlüğü aşağıdaki job_targets'tır.
          def peek_job(batch: false)
            @lock.synchronize { @pending_digests.first || (batch ? { batch: true } : nil) }
          end

          # İş defteri görünümü (issue #100 P2b): kuyruktaki + uçuştaki
          # hedefler. @lock altında YALNIZ kuyruk/sicil okunur — store'a
          # dokunulmaz (kilit sırası tekyönlü kalır).
          def job_targets
            @lock.synchronize do
              { queued: @pending_digests.map { |j| j[:target] || "batch compile" },
                in_flight: @distillers.values.map { |j| j[:target] || "batch compile" } }
            end
          end

          # Başarılı derlemenin hemen ardından DistillGate çağırır — ayak izi
          # o anki hale snapshot'lanır; sonraki flush ancak YENİ kalıcı
          # içerikte doğum kararı verir. Snapshot'ın kendisi patlarsa sayfa
          # zaten başarılı yazılmıştır: gate kirli kalır (bir sonraki
          # flush'ta yeniden snapshot denenir) — ekonomi kaybı, doğruluk değil.
          def mark_compiled!
            @lock.synchronize { @compile_footprint = footprint }
          end

          # Oturum annal'ının rubik:// URI'si (DistillGate.brief kaynak
          # listesi için okur). Annal yoksa nil — brif o kaynağı listelemez.
          def session_annal_uri
            rec = @store.get(type: "note", id: Vocabulary.session_ref(@session_slug))
            rec && @store.uri_for("note", rec["id"])
          end

          private

          # Doğum kararı: digest kuyruğu önceliklidir. İş claim→spawn→confirm
          # dizisiyle TEK kapıdan (@lock) alınır: maestro thread'i (submit)
          # ile worker'ın flush'u aynı iş için çift doğum yarışamaz; doğum
          # başarısızsa iş kuyruğa geri konur, sonraki flush'ta yeniden
          # denenir.
          def spawn_job!(batch:)
            return unless spawn_allowed?

            @lock.synchronize do
              job = claim_job(batch: batch)
              next unless job

              begin
                inst = @supervisor.spawn(
                  role: DISTILLER_ROLE, prompt: DistillGate.brief(self, job), type_name: TYPE_NAME,
                  # parent_id omitted — the root plane is spawn's default
                  # (ConversationId::ROOT_ID); storage stays plane-blind.
                  max_steps: @max_steps, model: @model || "inherit"
                )
                confirm(inst.id, job)
                Vakanuvis.log_via(@dmesg, :info, "distiller spawned for #{DistillGate.job_description(job)}")
                inst
              rescue StandardError => e
                restore_job(job)
                Vakanuvis.log_via(@dmesg, :warn,
                                  "distiller spawn failed (#{DistillGate.job_description(job)}): #{e.class}: #{e.message}")
                nil
              end
            end
          end

          # Bus yoksa hasat da olamaz (damıtıcının tamamlanma olayı gelmez):
          # doğum kapısı kapalı kalır, makbuz dürüst kalır.
          def spawn_allowed?
            @enabled && @event_bus.respond_to?(:subscribe) &&
              @supervisor.respond_to?(:spawn) &&
              @supervisor.respond_to?(:type_registry) && @supervisor.type_registry.get(TYPE_NAME)
          end

          # Aşağısı YALNIZ @lock altından çağrılır (çağıran: submit /
          # spawn_job! / completion_event) — kendi kilidi almaz.
          def claim_job(batch: false)
            @pending_digests.shift || (batch ? { batch: true, transcript_uris: source_transcript_uris } : nil)
          end

          def restore_job(job)
            @pending_digests.unshift(job) if job[:target]
          end

          def confirm(inst_id, job)
            @distillers[inst_id.to_s] = job
          end

          def dirty?
            @lock.synchronize { @compile_footprint.nil? || @compile_footprint != footprint }
          end

          # Kalıcı içerik ayak izi: sabit id + içerik hash'i + durum.
          # Annal'ın yalnız turn satırları ayıklanır; diğer not değişiklikleri
          # ve mevcut kart/sayfa güncellemeleri derleyiciyi yeniden kirletir.
          def footprint
            ["memory", "wiki", "note"].flat_map do |type|
              @store.list(type: type).sort_by(&:id).map do |summary|
                record = @store.get(type: type, id: summary.id)
                next [type, summary.id, nil] unless record

                hash = record["hash"]
                if type == "note" && (Vocabulary::ANNAL_TAGS - Array(record["tags"])).empty?
                  body = record["body"].to_s.lines.reject do |line|
                    line.match?(/\A- \[\d+\] turn .*\(event=turn\.\d+\.[^)]*\)\s*\z/)
                  end.join.rstrip
                  hash = Digest::SHA256.hexdigest([record["title"], body, record["tags"], record["links"]].to_json)
                end
                [type, summary.id, hash, record["status"]]
              end
            end
          end

          # Kaynak disiplini (v2 §4-V4): yalnız status=completed transcript
          # satırları; kronikçinin kendi etiketlileri hariç — özyinelemeli
          # kaynak kirliliği. En yeni N satır (updated_at, sonra row) —
          # deterministik sıra.
          def source_transcript_uris
            summaries = @store.list(type: "transcript").reject do |s|
              s.status != Vocabulary::TRANSCRIPT_COMPLETED || Array(s.tags).include?(Vocabulary::BASE_TAG)
            end
            summaries.sort_by { |s| [s.updated_at.to_s, s.row.to_i] }
                     .last(Harness::SOURCE_TRANSCRIPT_LIMIT)
                     .map { |s| @store.uri_for("transcript", s.id) }
          end
        end
      end
    end
  end
end
