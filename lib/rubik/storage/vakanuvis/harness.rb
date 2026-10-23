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
        RECALL_FALLBACK_LIMIT = 3
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

        attr_reader :store, :supervisor, :dmesg, :session_slug, :gate

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
          @dropped = 0
          @stopped = false
          @busy = 0
          @worker = nil
          # Damıtıcı doğum kapısı: kuyruk + sicil + kirli işaret Gate'de
          # (kurucu enjeksiyonu — gate Harness'e geri dokunmaz).
          @gate = DistillGate::Gate.new(store: @store, supervisor: @supervisor, dmesg: @dmesg,
                                        event_bus: @event_bus, enabled: @distiller_enabled,
                                        max_steps: @max_steps, model: @model, session_slug: @session_slug)
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
          @monitor.synchronize do
            return if @stopped

            @stopped = true
            @busy += 1 # STOP işaretinin de işleniş sayılır
            @queue.push(STOP)
          end
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
          unless payload.is_a?(Hash)
            Vakanuvis.log_via(@dmesg, :warn, "discarded non-hash #{kind} event (#{payload.class})")
            return false
          end

          @monitor.synchronize do
            return false if @stopped

            drop_oldest! if @queue.size >= @max_queue
            @busy += 1
            @queue.push([kind, payload])
            true
          end
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
          hits = DistillGate.active_recall_hits(@store, query: q, type: allowed).first(RECALL_LIMIT)
          unless hits.empty?
            lines = hits.map { |r| recall_line(r) }
            header = "Recalled #{hits.size} entit#{hits.size == 1 ? 'y' : 'ies'} for '#{AnnalWriter.one_line(q, 80)}':"
            return "#{header}\n#{lines.join("\n")}\nRead a full record with read_file(path: '<uri above>')."
          end

          relaxed_digest(q, allowed)
        end

        # record tool thread'inden, sweep worker'dan koşar — get-then-put
        # dansını tek kilide alınca çift satır açma yarışı kapanır (store
        # monitoru asla geri çağırmadığı için kilit sırası tekyönlü).
        def record(topic:, body:, links: {}, tags: [])
          @monitor.synchronize { MemorySteward.record(@store, topic: topic, body: body, links: links, tags: tags) }
        end

        def forget(ref:)
          raise ArgumentError, "forget: 'ref' is required" if ref.to_s.strip.empty?

          MemorySteward.forget(@store, ref: ref, retention: @retention)
        end

        # Asenkron (K9): istek kuyruğa yazılır, maestro'ya deterministik
        # makbuz döner — turn'ü asla LLM bekletilmez. Sınır nöbetçisi:
        # boş sorgu burada patlar (tool katmanı yakalar), gerisi Gate'e
        # delege (dedupe + doğum + makbuz orada).
        def digest(query)
          q = query.to_s.strip
          raise ArgumentError, "digest: 'query' is required" if q.empty?

          @gate.submit(q)
        end

        # İş kuyruğu görünürlüğü (issue #100 P2b): "yavaş kuyruk mu, düşen
        # iş mi" ayırt edilemezdi — makbuzdan sonra recall, derleme inene
        # dek hiçbir şey göstermiyordu. Deterministik dizgi.
        def digest_status
          targets = @gate.job_targets
          if targets[:queued].empty? && targets[:in_flight].empty?
            return "Digest queue: nothing queued, nothing in flight. " \
                   "recall shows compiled pages; a submitted digest appears here until it compiles."
          end

          "Digest queue: #{targets[:queued].size} queued (#{targets[:queued].join(', ')}), " \
            "#{targets[:in_flight].size} in flight (#{targets[:in_flight].join(', ')})."
        end

        # Soğuk-başlangıç yönelimi (issue #99 P2): ilk sorgu sözcük dağı
        # tahmin etmek zorunda kalmadan hangi konular var? Aktif ve mem.*
        # bağlı kartlar [ref, row] sırasıyla — deterministik.
        def topics
          bound = @store.refs.select { |ref, _| Vocabulary.memory_ref?(ref) }
          cards = @store.list(type: "memory").select do |s|
            s.status == Vocabulary::STATUS_ACTIVE && bound.value?(s.id)
          end
          if cards.empty?
            return "No memory topics recorded yet — teach the chronicler with " \
                   "vakanuvis(action: 'record', topic: ..., body: ...)."
          end

          lines = cards.sort_by { |s| [bound.key(s.id), s.row] }.filter_map do |s|
            record = @store.get(type: "memory", id: s.id)
            next unless record # list→get arası silme yarışı (review L2)

            "- #{bound.key(s.id)} — #{s.title} — #{first_body_line(record)} — #{@store.uri_for('memory', s.id)}"
          end
          "Recorded topics (#{lines.size}):\n#{lines.join("\n")}"
        end

        private

        # v2 §4-V2 + issue #99 P2: AND boşluğu tek tip körlük değil — en
        # yakın kısmi eşleşmeler dürüstçe "(fallback)" damgasıyla sunulur
        # (gerçek eşleşme değildir), transcript izleri kapsam ipucu olarak
        # sayılır. Ne fallback ne transcript izi varsa bugünkü dil/terim
        # yönlendirmesi birebir döner (keyword-AND'da en sık neden TR
        # sorgu ↔ EN gövde uyuşmazlığıdır; yanlış "hemen yeniden kaydet"
        # yönlendirmesi burada kesilir).
        def relaxed_digest(query, allowed)
          q = query.to_s.strip
          # Süpersede edilmiş sayılar "en yakın kısmi eşleşme" olarak
          # sunulmaz (review M1) — emekli bir sayfayı okumaya davet etmek,
          # issue #100'ün "iki kopya, biri bozuk" bulgusunun aynısıdır.
          relaxed = DistillGate.active_recall_hits(@store, query: q, type: allowed, require_all: false)
                               .first(RECALL_FALLBACK_LIMIT)
          transcripts = @store.search(query: q, type: "transcript")
          if relaxed.empty? && transcripts.empty?
            return "No chronicled knowledge matches '#{AnnalWriter.one_line(q, 80)}'. Recall is keyword-AND: retry with " \
                   "fewer or other-language terms first (e.g. the TR/EN Keywords: lines). If the knowledge is genuinely " \
                   "missing, record it (vakanuvis action 'record') or queue a digest."
          end

          parts = []
          # Başlık + read_file ayağı yalnız gerçek fallback izi varken
          # basılır (review CR#1: "yukarıdaki uri" diyecek uri yokken
          # olmayan bir talimat modele verilmesin).
          unless relaxed.empty?
            parts << "No exact keyword-AND match for '#{AnnalWriter.one_line(q, 80)}' — closest partial matches (fallback, not true matches):"
            parts.concat(relaxed.map { |r| "- (fallback) #{recall_line(r)}" })
          end
          unless transcripts.empty?
            parts << "#{transcripts.size} transcript entr#{transcripts.size == 1 ? 'y' : 'ies'} mention these terms — " \
                     "the raw session logs may hold it; queue a digest to compile them."
          end
          parts << "If none of these help, retry with fewer or other-language terms (the TR/EN Keywords: lines), " \
                   "record the knowledge, or queue a digest."
          parts << "Read a full record with read_file(path: '<uri above>')." unless relaxed.empty?
          parts.join("\n")
        end

        def first_body_line(record)
          slice = record["body"].to_s.lines.map(&:strip).reject(&:empty?).first.to_s.slice(0, RECALL_BODY_SLICE)
          slice.empty? ? "(no body)" : slice
        end

        def recall_line(record)
          "- #{record['title']} [#{record['id']}] #{first_body_line(record)} — #{@store.uri_for(record['type'], record['id'])}"
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
          # Önce kronik, sonra hasat; iki düzlemin hataları birbirini
          # engellemez. Annal yazılamasa da digest tamamlanır/geri kuyruğa alınır.
          seq = next_seq
          line = AnnalWriter.subagent_line(seq, payload)
          begin
            append_session([[event_key(payload), line]])
          ensure
            @gate.completion_event(payload)
          end
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
          Vakanuvis.upsert(@store, type: "note", ref: Vocabulary.goal_ref(ordinal),
                                   title: AnnalWriter.goal_title(ordinal, enriched[:goal]),
                                   body: goal_body.join("\n"), tags: Vocabulary::ANNAL_TAGS + [Vocabulary::GOAL_TAG],
                                   links: { "session" => Vocabulary.session_ref(@session_slug) })
          append_session(AnnalWriter.goal_lines(seq, enriched))
          maintain
        end

        # Goal sırası mağazadan türetilir (refs'teki en büyük annal.goal.<n>
        # + 1): süreç yeniden başlasa bile aynı depoda numara çakışmaz —
        # determinizm depo durumundan, saatlerden değil.
        def next_goal_ordinal
          @monitor.synchronize do
            max_ref = @store.refs.keys.filter_map { |k| Vocabulary.goal_ordinal(k) }.max.to_i
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
          @gate.flush_tick
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
          AnnalWriter.append(@store, ref: Vocabulary.session_ref(@session_slug),
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
