# frozen_string_literal: true

require "monitor"

module Rubik
  module Storage
    module Vakanuvis
      # Düzlem 1 — Deterministik Çekirdek: tek worker thread + sınırlı
      # FIFO kuyruk. Olay kapıları mevcut bus abonelikleridir (subagent
      # tamamlanma + goal bitişi — K3); NE ZAMAN, NEREYE, NASIL yazılacağı
      # burada kural tabanlıdır. Sessizlik sözleşmesi (§4.3): WAKE_KINDS
      # dışında kalır, notice yaymaz — sadece dmesg/stderr. Ömür: ctx
      # dispose'u LIFO ile kapatır (worker kill + abonelik geri alımı).
      class Harness
        STOP = :__vakanuvis_stop__
        MAX_QUEUE = 200
        RECALL_LIMIT = 5
        RECALL_BODY_SLICE = 140
        RECALL_TYPES = ["memory", "wiki"].freeze
        # v2 §4-V4: damıtıcı kaynak disiplini — yalnız TAMAMLANMIŞ
        # transcript'ler, damıtıcının kendisi Hariç (özyineleme kirliliği:
        # canlı depoda transcript satırları 'vakanuvis' etiketi taşır).
        SOURCE_TRANSCRIPT_LIMIT = 8
        # Literaller, depolama katmanını orchestrator require'larından
        # uzak tutar; test ikizleri her ikisini de sabitlere pinler:
        # Notices::COMPLETED_EVENT ve GoalState::FINISH_EVENT. TURN_EVENT
        # REPL TurnRecorder#emit_turn_finished kapısıdır (root-turn planı
        # 2026-10-04).
        SUBAGENT_EVENT = :subagent_completed
        GOAL_EVENT = :goal_finished
        TURN_EVENT = :turn_finished

        attr_reader :store, :supervisor, :dmesg, :session_slug, :model, :max_steps, :flush_events

        def initialize(store:, config: nil, event_bus: nil, supervisor: nil, dmesg: nil,
                       context: nil, session_slug: nil, max_queue: MAX_QUEUE)
          @store = store
          @config = config
          @event_bus = event_bus
          @supervisor = supervisor
          @dmesg = dmesg
          @context = context
          @session_slug = session_slug || self.class.mint_session_slug
          @flush_events = fetch_cfg("subagents.vakanuvis.flush_events", 10).to_i
          @max_steps = fetch_cfg("subagents.vakanuvis.max_steps", 8).to_i
          @model = fetch_cfg("subagents.vakanuvis.model", nil)
          @retention = fetch_cfg("subagents.vakanuvis.retention", "supersede").to_s
          @distiller_enabled = fetch_cfg("subagents.vakanuvis.distiller", true) != false
          @root_turns = fetch_cfg("subagents.vakanuvis.root_turns", true) != false
          @max_queue = max_queue.to_i
          @queue = Thread::Queue.new
          @monitor = Monitor.new
          @seq = 0
          @goal_ordinal = 0
          @turn_ordinal = 0
          @events_since_distill = 0
          @pending_digests = []
          @distillers = {}
          @dropped = 0
          @stopped = false
          @busy = 0
          @gate_mutex = Mutex.new
          @worker = nil
          # v2 §4-V5: kirli işareti — son başarılı derlemeden bu yana KALICI
          # içerik (memory+wiki+note satır ayak izi) değişmediyse toplu
          # damıtıcı doğmaz. Turn satırları ayak izini değiştirmez: saf
          # turn akışında derleme boşa yakılmaz.
          @compile_footprint = nil
        end

        class << self
          # Oturum slug'ı: tek süreçte deterministik, süreçler arasında
          # ayrışır. Replay testleri sabit slug enjekte eder.
          def mint_session_slug
            "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}"
          end
        end

        # ---- yaşam döngüsü -------------------------------------------------

        def start!
          subscribe_events
          @worker = Thread.new { run_worker }
          @worker.name = "rubik-vakanuvis" if @worker.respond_to?(:name=)
          self
        end

        def stopped? = @monitor.synchronize { @stopped }

        # Dispose yolu: FIFO'daki her şey (STOP dahil öncesindeki olaylar)
        # işlenir, sonra thread sonlanır. Kalan olay yarımda kalmaz; thread
        # 2 saniyede durmazsa (yavaş bir flush/spawn içinde) kill gelir ve
        # işlenemeyen olay sayısı dmesg'e düşer — sessiz kayıp yok.
        def shutdown
          @monitor.synchronize { @stopped = true }
          @monitor.synchronize { @busy += 1 } # STOP işaretinin de işleniş sayılır
          @queue.push(STOP)
          @worker&.join(2)
          if @worker&.alive?
            Vakanuvis.log_via(@dmesg, :warn, "worker did not stop in 2s — killing with #{queue_size} event(s) unprocessed")
            @worker.kill
          end
          @worker = nil
        end

        def wait_idle(timeout: 2.0)
          deadline = Time.now + timeout
          sleep 0.01 while busy? && Time.now < deadline
          !busy?
        end

        # Kuyrukta + uçuştaki olay sayısı (push'ta artar, işlenince/düşürülünce
        # azalır) — pop ile işaretleme arasındaki yarış penceresini kapatır.
        def busy? = @monitor.synchronize { @busy.positive? }

        # ---- olay giriş kapıları (kworker thread'inde çağrılır) -----------

        def enqueue_event(kind, payload)
          return false if stopped?

          unless payload.is_a?(Hash)
            Vakanuvis.log_via(@dmesg, :warn, "discarded non-hash #{kind} event (#{payload.class})")
            return false
          end

          drop_oldest! if @queue.size >= @max_queue
          @monitor.synchronize { @busy += 1 }
          @queue.push([kind, payload])
          true
        end

        def queue_size = @queue.size

        # ---- talep düzlemi (maestro aracı buraya delege eder; K7) ---------

        # Tam deterministik, LLM'siz: Store#search_ranked BM25-lite sırası +
        # RECALL_TYPES kısıtı + ilk RECALL_LIMIT kayıt ⇒ aynı depo ⇒ aynı
        # digest. type: dizisi (v2 §4-V8) transcript/note gibi arama dışı
        # tipleri hiç parse etmez; sıralama politika kararına aittir —
        # Store#search'in [type,row] sözleşmesi değişmez.
        def recall(query, types: RECALL_TYPES)
          q = query.to_s.strip
          raise ArgumentError, "recall: 'query' is required" if q.empty?

          allowed = Array(types).map(&:to_s)
          allowed = RECALL_TYPES if allowed.empty?
          hits = @store.search_ranked(query: q, type: allowed).first(RECALL_LIMIT)
          unless hits.empty?
            lines = hits.map { |r| recall_line(r) }
            header = "Recalled #{hits.size} entit#{hits.size == 1 ? 'y' : 'ies'} for '#{AnnalWriter.one_line(q, 80)}':"
            return "#{header}\n#{lines.join("\n")}\nRead a full record with read_file(path: '<uri above>')."
          end

          # v2 §4-V2: boş dönüş önce dil/terim uyarısı — keyword-AND'da en
          # sık neden TR sorgu ↔ EN gövde sözcük uyuşmazlığıdır; yanlış
          # yönlendirme (hemen yinelenen kart kaydet) burada kesilir.
          "No chronicled knowledge matches '#{AnnalWriter.one_line(q, 80)}'. Recall is keyword-AND: retry with " \
            "fewer or other-language terms first (e.g. the TR/EN Keywords: lines). If the knowledge is genuinely " \
            "missing, record it (vakanuvis action 'record') or queue a digest."
        end

        # record tool thread'inden, sweep worker'dan koşar — get-then-put
        # dansını tek kilide alınca çift satır açma yarışı kapanır (store
        # monitoru asla geri çağırmadığı için kilit sırası tekyönlü).
        def record(topic:, body:, links: {})
          @monitor.synchronize { MemorySteward.record(@store, topic: topic, body: body, links: links) }
        end

        def forget(ref:)
          raise ArgumentError, "forget: 'ref' is required" if ref.to_s.strip.empty?

          MemorySteward.forget(@store, ref: ref, retention: @retention)
        end

        # Asenkron (K9): istek kuyruğa yazılır, maestro'ya deterministik
        # makbuz döner — turn'ü asla LLM bekletilmez. Damıtıcı sonra
        # önerir, yazmayı Düzlem 1 yapar. İş, makbuz ANINDA kaynak
        # listesini de taşır (v2 §4-V4): completed-only, vakanuvis-hariç.
        def digest(query)
          q = query.to_s.strip
          raise ArgumentError, "digest: 'query' is required" if q.empty?

          target = DistillGate.digest_target_ref(q)
          # v2 §4-V5: aynı hedefli iş zaten kuyrukta ya da uçuştaysa makbuz
          # 'already queued' varyantına düşer — çift doğum yok. Denetim +
          # itme TEK kritik bölümde ve doğum kapısı (with_gate) altında:
          # maybe_spawn'ın claim→spawn→confirm penceresinde de iş kayıp
          # görünmez (review: TOCTOU). Kilit sırası with_gate → @monitor,
          # maybe_spawn ile aynı yönde.
          in_flight = with_gate do
            @monitor.synchronize do
              busy = @pending_digests.any? { |j| j[:target] == target } ||
                     @distillers.any? { |_id, j| j[:target] == target }
              @pending_digests << { query: q, target: target, transcript_uris: source_transcript_uris } unless busy
              busy
            end
          end
          if in_flight
            return "Digest already queued for '#{target}' (#{AnnalWriter.one_line(q, 60)}): the chronicler is " \
                   "compiling it — recall it later with vakanuvis(action: 'recall', query: '...')."
          end

          spawned = DistillGate.maybe_spawn(self, batch: false)
          DistillGate.receipt(query: q, target: target, spawned: !spawned.nil?)
        end

        # ---- Düzlem 2 bağlantıları (DistillGate kullanır) ------------------

        # Bus yoksa hasat da olamaz (damıtıcının tamamlanma olayı gelmez):
        # doğum kapısı kapalı kalır, makbuz dürüst kalır.
        def distiller_spawn_allowed?
          @distiller_enabled && @event_bus.respond_to?(:subscribe) &&
            @supervisor.respond_to?(:spawn) &&
            @supervisor.respond_to?(:type_registry) && @supervisor.type_registry.get(DistillGate::TYPE_NAME)
        end

        # Doğum kapısı: claim→spawn→confirm dizisi tek mutex arkasından
        # yürür — maestro tool thread'i (digest) ile worker'ın (maintain)
        # aynı iş için çift doğum yarışı olamaz.
        def with_gate(&) = @gate_mutex.synchronize(&)

        # İşi KUYRUKTAN ALIR (claim). Doğum başarısız olursa restore ile
        # geri konur; hiçbir durumda iş iki kez doğmaz ya da sessizce
        # kaybolmaz. Toplu derleme için sentetik batch işi üretir — kaynak
        # listesi o anın disiplinli anlık görüntüsüdür (v2 §4-V4).
        def claim_digest_job(batch: false)
          @monitor.synchronize do
            @pending_digests.shift || (batch ? { batch: true, transcript_uris: source_transcript_uris } : nil)
          end
        end

        def restore_digest_job(job)
          @monitor.synchronize { @pending_digests.unshift(job) } if job[:target]
        end

        def confirm_spawned(inst_id, job)
          @monitor.synchronize { @distillers[inst_id.to_s] = job }
        end

        # Salt-okuma peeki (test/kurcalama yüzeyi): kuyruğun başını gösterir.
        def peek_digest_job(batch: false)
          @monitor.synchronize { @pending_digests.first || (batch ? { batch: true } : nil) }
        end

        # ---- v2 §4-V5: kirli işaret (PUBLIC — DistillGate hasadı çağırır) --

        # Kalıcı içerik ayak izi: kart + sayfa + not (annal dahil) satır
        # sayıları. Turn satırları mevcut annal notuna satır ekler, ayak
        # izini değiştirmez — saf turn akışında derleme boşa yakılmaz.
        def compile_footprint
          ["memory", "wiki", "note"].sum { |t| @store.list(type: t).size }
        end

        def compile_dirty?
          @monitor.synchronize { @compile_footprint.nil? || @compile_footprint != compile_footprint }
        end

        # Başarılı derlemenin hemen ardından DistillGate çağırır — ayak izi
        # o anki hale snapshot'lanır; sonraki maintain ancak YENİ kalıcı
        # içerikte doğum kararı verir.
        def mark_compiled!
          @monitor.synchronize { @compile_footprint = compile_footprint }
        end

        def session_annal_uri
          rec = @store.get(type: "note", id: AnnalWriter.session_ref(@session_slug))
          rec && @store.uri_for("note", rec["id"])
        end

        # Kaynak disiplini (v2 §4-V4): yalnız status=completed transcript
        # satırları; 'vakanuvis' etiketliler (damıtıcının kendisi) hariç —
        # özyinelemeli kaynak kirliliği. En yeni N satır (updated_at, sonra
        # row) — deterministik sıra.
        def source_transcript_uris
          summaries = @store.list(type: "transcript").reject do |s|
            s.status != "completed" || Array(s.tags).include?("vakanuvis")
          end
          summaries.sort_by { |s| [s.updated_at.to_s, s.row.to_i] }
                   .last(SOURCE_TRANSCRIPT_LIMIT)
                   .map { |s| @store.uri_for("transcript", s.id) }
        end

        private

        def recall_line(record)
          slice = record["body"].to_s.lines.map(&:strip).reject(&:empty?).first.to_s.slice(0, RECALL_BODY_SLICE)
          "- #{record['title']} [#{record['id']}] #{slice} — #{@store.uri_for(record['type'], record['id'])}"
        end

        def subscribe_events
          return unless @event_bus.respond_to?(:subscribe)

          # Aboneliğin geri alımı ctx.on_dispose ile aynı nefeste (§1A):
          # dispatcher subscribe'a verilen context'e unregister inverse'i
          # kendisi bağlar.
          @event_bus.subscribe(SUBAGENT_EVENT, context: @context) { |p| enqueue_event(:subagent, p) }
          @event_bus.subscribe(GOAL_EVENT, context: @context) { |p| enqueue_event(:goal, p) }
          return unless @root_turns

          # Kök-turn kapısı knob arkasında (R7): kapalıyken abonelik hiç
          # kurulmaz, :turn_finished olayı kronikçiye akmaz.
          @event_bus.subscribe(TURN_EVENT, context: @context) { |p| enqueue_event(:turn, p) }
        end

        # Taşma düşürmesi asla STOP işaretini yutamaz (yutsa worker hiç
        # sonlanamazdı): STOP geldiyse kuyruğun sonuna geri konur.
        def drop_oldest!
          item = @queue.pop(true)
          if item == STOP
            @queue.push(STOP)
          else
            @monitor.synchronize do
              @dropped += 1
              @busy -= 1
            end
            Vakanuvis.log_via(@dmesg, :warn, "event queue overflow — dropped oldest (total: #{@dropped})")
          end
        rescue ThreadError
          nil
        end

        def run_worker
          loop do
            kind, payload = @queue.pop
            break if kind == STOP

            handle_event(kind, payload)
          ensure
            @monitor.synchronize { @busy -= 1 }
          end
        end

        # TranscriptIndexer disiplini: kronikçinin kendi hatası akışı
        # asla bozmaz — uyarı düşer, sonraki olay işlenir.
        def handle_event(kind, payload)
          case kind
          when :subagent then handle_subagent(payload)
          when :goal then handle_goal(payload)
          when :turn then handle_turn(payload)
          end
        rescue StandardError => e
          Vakanuvis.log_via(@dmesg, :warn, "event handling failed (#{kind}): #{e.class}: #{e.message}")
        end

        def handle_subagent(payload)
          # Önce kronik (Düzlem 1 garantisi), sonra hasat (Düzlem 2): hasat
          # patlarsa bile olayın annal satırı yazılmış olur — deterministik
          # katman LLM katmanının hatasından zarar görmez.
          seq = next_seq
          line = AnnalWriter.subagent_line(seq, payload)
          append_session([[event_key(payload), line]])
          harvest_distiller(payload)
          maintain if flush_due?
        end

        # Kök-turn kroniği: ordinal session-slug süreç-başına mint
        # edildiğinden harness-lokal sayaç yeterli (yeni süreç = yeni
        # session annal; goal sırasındaki mağazadan-türetme burada
        # gereksiz). Turn olayı flush sayacına sayılır ama koşulsuz
        # maintain tetiklemez — turn sıklığı yüksek (R8).
        def handle_turn(payload)
          ordinal = @monitor.synchronize { @turn_ordinal += 1 }
          seq = next_seq
          append_session([AnnalWriter.turn_line(seq, ordinal, payload)])
          maintain if flush_due?
        end

        def handle_goal(payload)
          ordinal = next_goal_ordinal
          enriched = payload.merge(goal_ordinal: ordinal)
          seq = next_seq
          goal_body = [AnnalWriter.goal_header_line(enriched[:goal])] +
                      AnnalWriter.goal_lines(seq, enriched).map { |_k, l| l }
          Vakanuvis.upsert(@store, type: "note", ref: AnnalWriter.goal_ref(ordinal),
                                   title: AnnalWriter.goal_title(ordinal, enriched[:goal]),
                                   body: goal_body.join("\n"), tags: AnnalWriter::ANNAL_TAGS + ["goal"],
                                   links: { "session" => AnnalWriter.session_ref(@session_slug) })
          append_session(AnnalWriter.goal_lines(seq, enriched))
          maintain
        end

        # Goal sırası mağazadan türetilir (refs'teki en büyük annal.goal.<n>
        # + 1): süreç yeniden başlasa bile aynı depoda numara çakışmaz —
        # determinizm depo durumundan, saatlerden değil.
        def next_goal_ordinal
          @monitor.synchronize do
            max_ref = @store.refs.keys.filter_map { |k| k[/\Aannal\.goal\.(\d+)\z/, 1]&.to_i }.max.to_i
            @goal_ordinal = [@goal_ordinal, max_ref].max + 1
          end
        end

        # Flush sayacı (R8): subagent ve turn olayları aynı ölçüde sayılır;
        # flush_events eşiği aşılınca true döner ve sayaç sıfırlanır.
        def flush_due?
          @monitor.synchronize do
            @events_since_distill += 1
            crossed = @events_since_distill >= @flush_events
            @events_since_distill = 0 if crossed
            crossed
          end
        end

        # Flush bakımı (yalnızca flush noktalarında — flush_events eşiği
        # aşımı veya goal bitişi): kaçak memory süpürme (K9) + wiki home
        # yeniden hesap + damıtıcı doğum kararı. v2 §4-V5: toplu doğum
        # yalnızca kirli işaretle — kalıcı içerik değişmediyse (yalnızca
        # turn satırları biriktiyse) damıtıcı yakılmaz.
        def maintain
          # Sweep record() ile aynı kilide koşar (tek-yazar disiplini):
          # get-then-put dansı çift satır açamaz.
          swept = @monitor.synchronize { MemorySteward.sweep_rogue_memory(@store) }
          Vakanuvis.log_via(@dmesg, :info, "steward swept #{swept} rogue memory row(s)") if swept.positive?
          WikiSkeleton.rebuild_home(@store)
          DistillGate.maybe_spawn(self, batch: true) if compile_dirty?
        end

        # Hasat: makbuzun sözü ancak TAMAMLANMIŞ damıtıcı geçerli öneri
        # üretince tutulur. Bitmemiş koşu (failed/budget/killed) digest
        # işini kuyruğa GERİ koyar — sonraki flush'ta yeniden doğar;
        # şema reddi ise yalnız o öneriyi düşürür (§4.2.4). Hasatın
        # KENDİSİ patlarsa da (disk hatası, bozuk satır — review:
        # sessiz-yutma sınıfı) iş kaybolmaz: hedefli iş kuyruğa geri
        # konur, toplu iş dürüstçe düşer.
        def harvest_distiller(payload)
          job = @monitor.synchronize { @distillers.delete(payload[:id].to_s) }
          return unless job

          # Get + hasat TEK kurtarma bölgesinde: supervisor.get/inst.result
          # (hedeflenmemiş double, kayıp kayıt) ve DistillGate.harvest
          # (disk hatası, bozuk satır) raise ederse iş kaybolmaz — hedefli
          # iş kuyruğa geri konur (review: sessiz-yutma sınıfı), toplu iş
          # dürüstçe düşer.
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
              @monitor.synchronize { @pending_digests << job }
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
              @monitor.synchronize { @pending_digests << job }
              Vakanuvis.log_via(@dmesg, :warn,
                                "distiller for #{job[:target]} ended state=#{payload[:state]} — digest requeued")
            else
              Vakanuvis.log_via(@dmesg, :warn, "batch distiller ended state=#{payload[:state]} — compile dropped")
            end
          when :crashed, :rejected then nil # kendi dalında detay loglandı (crash requeue/drop; B6 ret sebebi + trim)
          else
            Vakanuvis.log_via(@dmesg, :warn, "distiller proposal rejected (schema/length) — dropped, store untouched")
          end
        end

        def append_session(lines)
          overflow = nil
          @monitor.synchronize do
            if @dropped.positive?
              seq = @seq += 1
              overflow = [["dropped.#{seq}", "- [#{seq}] #{@dropped} event(s) dropped — queue overflow (event=dropped.#{seq})"]]
              @dropped = 0
            end
          end
          AnnalWriter.append(@store, ref: AnnalWriter.session_ref(@session_slug),
                                     title: AnnalWriter.session_title(@session_slug),
                                     lines: lines + overflow.to_a)
        end

        def next_seq = @monitor.synchronize { @seq += 1 }

        def event_key(payload)
          sid = payload[:storage_id].to_s
          sid = payload[:id].to_s if sid.empty?
          "subagent.#{sid}.#{payload[:state]}"
        end

        def fetch_cfg(key, default)
          @config.respond_to?(:fetch) ? @config.fetch(key, default) : default
        end
      end
    end
  end
end
