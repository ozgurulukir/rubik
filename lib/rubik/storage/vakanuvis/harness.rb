# frozen_string_literal: true

require "monitor"

module Rubik
  module Storage
    module Vakanuvis
      # Düzlem 1 — Deterministik Çekirdek: tek worker thread + sınırlı FIFO
      # kuyruk (Concurrency::Worker iskeleti: atomik kabul, idempotent
      # kapanış, busy sayımı ve son-çare ağı iskelettedir). Olay kapıları
      # mevcut bus abonelikleridir (subagent tamamlanma + goal bitişi — K3);
      # NE ZAMAN, NEREYE, NASIL yazılacağı burada kural tabanlıdır.
      # Sessizlik sözleşmesi (§4.3): WAKE_KINDS dışında kalır, notice yaymaz —
      # sadece dmesg/stderr. Ömür: ctx dispose'u LIFO ile kapatır (worker kill + abonelik geri alımı).
      class Harness
        include Concurrency::Worker

        # STOP işareti iskeletin tek ev sahibinde; sabit adı kuyruk gözetimi
        # ve test ikizleri için yaşar.
        STOP = Concurrency::Worker::STOP
        MAX_QUEUE = 200
        # v2 §4-V4: damıtıcı kaynak disiplini — yalnız TAMAMLANMIŞ transcript'ler,
        # damıtıcının kendisi Hariç (özyineleme kirliliği: canlı depoda transcript satırları 'vakanuvis' etiketi taşır).
        SOURCE_TRANSCRIPT_LIMIT = 8
        # Literaller, depolama katmanını orchestrator require'larından
        # uzak tutar; test ikizleri her ikisini de sabitlere pinler:
        # Notices::COMPLETED_EVENT ve GoalState::FINISH_EVENT. TURN_EVENT,
        # REPL TurnRecorder#emit_turn_finished kapısıdır (root-turn planı 2026-10-04).
        SUBAGENT_EVENT = :subagent_completed
        GOAL_EVENT = :goal_finished
        TURN_EVENT = :turn_finished
        # Askı kroniği (tarama kartı 2, 2026-11-01): GoalState::SUSPEND_EVENT — abonelik
        # :goal akışına yazar; worker status=="suspended" ile ayırt eder.
        SUSPEND_EVENT = :goal_suspended

        attr_reader :store, :config, :supervisor, :dmesg, :session_slug, :gate

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
          @auto_digest = fetch_cfg("subagents.vakanuvis.auto_digest", true) != false
          @root_turns = fetch_cfg("subagents.vakanuvis.root_turns", true) != false
          @max_queue = max_queue.to_i
          @queue = Thread::Queue.new
          @monitor = Monitor.new
          @seq = @goal_ordinal = @turn_ordinal = @events_since_distill = @dropped = @busy = 0
          @stopped = false
          @worker = nil
          @touched_topics = Set.new
          # Damıtıcı doğum kapısı: kuyruk + sicil + kirli işaret Gate'de
          # (kurucu enjeksiyonu — gate Harness'e geri dokunmaz).
          @gate = DistillGate::Gate.new(
            store: @store, supervisor: @supervisor, dmesg: @dmesg, event_bus: @event_bus, enabled: @distiller_enabled, max_steps: @max_steps,
            model: @model, session_slug: @session_slug,
            max_digest_jobs: fetch_cfg("subagents.vakanuvis.max_digest_jobs", DistillGate::Gate::DEFAULT_MAX_DIGEST_JOBS)
          )
        end

        # Oturum slug'ı: tek süreçte deterministik, süreçler arasında
        # ayrışır. Replay testleri sabit slug enjekte eder.
        def self.mint_session_slug = "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}"

        # ---- yaşam döngüsü -------------------------------------------------

        def start!
          subscribe_events
          @worker = Thread.new { run_worker }
          @worker.name = "rubik-vakanuvis" if @worker.respond_to?(:name=)
          self
        end

        # ---- olay giriş kapıları (kworker thread'inde çağrılır) -----------

        # Atomik kabul (stopped-kontrol + push tek kritik bölümde) iskelette:
        # kapanış yarışındaki olay ya STOP'tan önce düşer ve işlenir ya da
        # reddedilir — arada kalan işleyeneksiz olay kalamaz.
        def enqueue_event(kind, payload)
          unless payload.is_a?(Hash)
            Vakanuvis.log_via(@dmesg, :warn, "discarded non-hash #{kind} event (#{payload.class})")
            return false
          end
          super
        end

        # ---- talep düzlemi (maestro aracı buraya delege eder; K7) ---------

        # Deterministik geri çağırma Recall düzleminde (recall.rb); burada
        # yalnız delege — araç yüzeyi (K7) ve test ikizleri bu imzaya pinli.
        def recall(query, types: Recall::RECALL_TYPES)
          Recall.recall(@store, query, types: types)
        end

        def auto_digest? = @auto_digest

        def touched_topics = @monitor.synchronize { @touched_topics.to_a }

        # record tool thread'inden, sweep worker'dan koşar — get-then-put
        # dansını tek kilide alınca çift satır açma yarışı kapanır (store
        # monitoru asla geri çağırmadığı için kilit sırası tekyönlü). Kayıt
        # + touched-topic izi TEK kritik bölümde: aradaki pencere, koşan
        # bir drain'in konuyu kaçırmasın (review #346).
        def record(topic:, body:, links: {}, tags: [])
          clean_topic = topic.to_s.strip
          @monitor.synchronize do
            rec = MemorySteward.record(@store, topic: clean_topic, body: body, links: links, tags: tags)
            @touched_topics << clean_topic unless clean_topic.empty?
            rec
          end
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
            return "Digest queue: nothing queued, nothing in flight. recall shows compiled pages; a submitted digest appears here until it compiles."
          end

          "Digest queue: #{targets[:queued].size} queued (#{digest_target_summary(targets[:queued])}), " \
            "#{targets[:in_flight].size} in flight (#{digest_target_summary(targets[:in_flight])})."
        end

        # Soğuk-başlangıç yönelimi (issue #99 P2): ilk sorgu sözcük dağı
        # tahmin etmek zorunda kalmadan hangi konular var? Aktif ve mem.*
        # bağlı kartlar [ref, row] sırasıyla — deterministik.
        def topics(limit: nil)
          lines, total = Orientation.topic_lines(@store, limit: limit)
          return "No memory topics recorded yet — teach the chronicler with vakanuvis(action: 'record', topic: ..., body: ...)." if lines.empty?

          count_label = limit && total > lines.size ? "#{lines.size} of #{total}" : lines.size.to_s
          "Recorded topics (#{count_label}):\n#{lines.join("\n")}"
        end

        private

        def digest_target_summary(targets)
          shown = targets.first(10)
          shown << "+#{targets.size - 10} targets" if targets.size > 10
          shown.join(", ")
        end

        # Abonelik geri alımı dispatcher'a aittir (§1A: subscribe'a verilen context'e
        # unregister inverse'i kendisi bağlar); TURN aboneliği R7 knob'unun arkasındadır.
        def subscribe_events
          return unless @event_bus.respond_to?(:subscribe)

          @event_bus.subscribe(SUBAGENT_EVENT, context: @context) { |p| enqueue_event(:subagent, p) }
          @event_bus.subscribe(GOAL_EVENT, context: @context) { |p| enqueue_event(:goal, p) }
          @event_bus.subscribe(SUSPEND_EVENT, context: @context) { |p| enqueue_event(:goal, p) }
          @event_bus.subscribe(TURN_EVENT, context: @context) { |p| enqueue_event(:turn, p) } if @root_turns
        end

        # ---- Concurrency::Worker iskelet kancaları --------------------------

        def worker_max_queue = @max_queue

        def worker_warn(message) = Vakanuvis.log_via(@dmesg, :warn, message)

        # Kapanış yolundaki son damıtım fırsatı (spawn yok — zombi doğum
        # engeli); hata yalıtılmış: worker sökümü devam eder.
        def worker_before_join
          auto_digest_touched!(spawn: false)
        rescue StandardError => e
          Vakanuvis.log_via(@dmesg, :warn, "shutdown auto-digest failed (#{e.class}: #{e.message}) — worker teardown continues")
        end

        def worker_drop_accounted(_item)
          @monitor.synchronize { @dropped += 1 }
          Vakanuvis.log_via(@dmesg, :warn, "event queue overflow — dropped oldest (total: #{@dropped})")
        end

        def worker_dispatch_failed(kind, _payload, error)
          # A dispatch-lost event must leave a chronicle trace — overflow
          # drops are ledgered, silence here would make the session record
          # look complete when it is not.
          Vakanuvis.log_via(@dmesg, :warn, "chronicler worker event dispatch failed (#{error.class}: #{error.message}) — #{kind} event lost, worker continues")
        end

        # TranscriptIndexer disiplini: kronikçinin kendi hatası akışı
        # asla bozmaz — uyarı düşer, sonraki olay işlenir. Kimlik eki
        # (F7) AnnalWriter.event_context'te.
        def handle_event(kind, payload)
          case kind
          when :subagent then handle_subagent(payload)
          when :goal then handle_goal(payload)
          when :turn then handle_turn(payload)
          end
        rescue StandardError => e
          # İlk backtrace karesi (event_loop.rb kuralı): depo hatasını
          # annal/digest hatasından ayırt eder.
          Vakanuvis.log_via(@dmesg, :warn, "event handling failed (#{kind}#{AnnalWriter.event_context(kind, payload)}): #{e.class}: #{e.message} @ #{(e.backtrace || []).first}")
        end

        def handle_subagent(payload)
          # Önce kronik, sonra hasat; iki düzlemin hataları birbirini
          # engellemez. Annal yazılamasa da digest tamamlanır/geri kuyruğa alınır.
          seq = next_seq
          begin
            append_session([[event_key(payload), AnnalWriter.subagent_line(seq, payload)]])
          ensure
            @gate.completion_event(payload)
          end
          maintain if flush_due?
        end

        # Kök-turn kroniği: ordinal session-slug süreç-başına mint edildiğinden
        # harness-lokal sayaç yeterli (yeni süreç = yeni session annal; goal
        # sırasındaki mağazadan-türetme burada gereksiz). Turn olayı flush
        # sayacına sayılır ama koşulsuz maintain tetiklemez — turn sıklığı yüksek (R8).
        def handle_turn(payload)
          ordinal = @monitor.synchronize { @turn_ordinal += 1 }
          seq = next_seq
          append_session([AnnalWriter.turn_line(seq, ordinal, payload)])
          maintain if flush_due?
        end

        def handle_goal(payload)
          if payload[:status].to_s == "suspended" # askı kroniği: satır düşer, mint/upsert/maintain yok (kart 2)
            seq = next_seq # anahtar hedef kimliği — sıra peek'i değil (issue #350)
            return append_session(AnnalWriter.suspend_line(seq, payload))
          end
          ordinal = next_goal_ordinal
          enriched = payload.merge(goal_ordinal: ordinal)
          seq = next_seq
          goal_body = [AnnalWriter.goal_header_line(enriched[:goal])] + AnnalWriter.goal_lines(seq, enriched).map { |_k, l| l }
          Vakanuvis.upsert(@store, type: "note", ref: Vocabulary.goal_ref(ordinal),
                                   title: AnnalWriter.goal_title(ordinal, enriched[:goal]), body: goal_body.join("\n"),
                                   tags: Vocabulary::ANNAL_TAGS + [Vocabulary::GOAL_TAG], links: { "session" => Vocabulary.session_ref(@session_slug) })
          append_session(AnnalWriter.goal_lines(seq, enriched))
          maintain(goal_end: true, goal_ordinal: ordinal)
        end

        # Goal sırası mağazadan türetilir (refs'teki en büyük annal.goal.<n>
        # + 1): süreç yeniden başlasa bile aynı depoda numara çakışmaz.
        # Askı artık peek ETMEZ (issue #350) — sıra yalnız bitişte mint edilir.
        def next_goal_ordinal = @goal_ordinal = peek_goal_ordinal

        def peek_goal_ordinal
          @monitor.synchronize { [@goal_ordinal, @store.refs.keys.filter_map { |k| Vocabulary.goal_ordinal(k) }.max.to_i].max + 1 }
        end

        # Flush sayacı (R8): subagent ve turn olayları aynı ölçüde sayılır;
        # flush_events eşiği aşılınca true döner ve sayaç sıfırlanır.
        def flush_due?
          @monitor.synchronize do
            crossed = (@events_since_distill += 1) >= @flush_events
            @events_since_distill = 0 if crossed
            crossed
          end
        end

        # Flush bakımı (yalnızca flush noktalarında — flush_events eşiği
        # aşımı veya goal bitişi): kaçak memory süpürme (K9) + wiki home
        # yeniden hesap + dokunulan hafıza konularının otomatik damıtımı +
        # damıtıcı doğum kararı. v2 §4-V5: toplu doğum yalnızca kirli işaretle;
        # hedefli damıtım TÜM konuları kuyrukladıysa toplu doğum atlanır — kayıp/red varsa batch telafi eder.
        def maintain(goal_end: false, goal_ordinal: nil)
          # Sweep record() ile aynı kilide koşar (tek-yazar disiplini):
          # get-then-put dansı çift satır açamaz.
          swept = @monitor.synchronize { MemorySteward.sweep_rogue_memory(@store) }
          Vakanuvis.log_via(@dmesg, :info, "steward swept #{swept} rogue memory row(s)") if swept.positive?
          WikiSkeleton.rebuild_home(@store)
          digested = auto_digest_touched!(spawn: !stopped?, goal_ordinal: goal_ordinal) if goal_end
          @gate.flush_tick unless stopped? || digested
        end

        # Otomatik damıtım kapısı (issue #341): hedef tamamlanmasında veya
        # kapanışta dokunulan konuları hedeflenmiş wiki derlemesi için kuyruklar;
        # spawn=false (kapanış) zombi LLM doğumunu engeller. Konu-başı yalıtım
        # (review #346): tek başarısız/red'li submit kalan konuları kaybettirmez —
        # kayıplar @touched_topics'e geri alınır, bir sonraki flush noktası dener.
        def auto_digest_touched!(spawn: true, goal_ordinal: nil)
          return false unless @auto_digest && @distiller_enabled

          spawn_allowed = spawn && !stopped?
          topics = @monitor.synchronize { @touched_topics.to_a.tap { @touched_topics.clear } }
          return false if topics.empty?

          stranded = topics.reject do |topic|
            _receipt, status = @gate.submit_with_status(topic, spawn: spawn_allowed, goal_ordinal: goal_ordinal)
            next true if status == :duplicate && Vakanuvis.log_duplicate_digest(@dmesg, topic, goal_ordinal) # F9: sessiz başarı değil
            next true unless status == :full

            Vakanuvis.log_via(@dmesg, :warn, "auto-digest refused for '#{topic}' (gate capacity full) — kept for the next goal end or shutdown")
            false
          rescue StandardError => e
            Vakanuvis.log_via(@dmesg, :warn, "auto-digest submit failed for '#{topic}' (#{e.class}: #{e.message})")
            false
          end
          @monitor.synchronize { stranded.each { |t| @touched_topics << t } } unless stranded.empty?
          unless spawn_allowed
            queued = topics - stranded
            note = "shutdown: #{queued.size} touched topic(s) queued but not spawned — they will not compile this session: #{queued.join(', ')}"
            note += "; #{stranded.size} refused/failed topic(s) kept for the next flush point (warnings above)" unless stranded.empty?
            Vakanuvis.log_via(@dmesg, :warn, note)
          end
          # Kapalı doğum: kapı :accepted dedi ama damıtıcı hiç doğamaz —
          # uyarı yoksa topic'ler tüm oturum kuyrukta sessizce birikirdi.
          if spawn_allowed && @gate.respond_to?(:spawn_allowed?) && !@gate.spawn_allowed?
            queued = topics - stranded
            unless queued.empty?
              note = "auto-digest queued #{queued.size} touched topic(s) but no distiller can run (spawn disabled)"
              Vakanuvis.log_via(@dmesg, :warn, "#{note} — they will not compile this session: #{queued.join(', ')}")
            end
          end
          stranded.empty?
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
          AnnalWriter.append(@store, ref: Vocabulary.session_ref(@session_slug), title: AnnalWriter.session_title(@session_slug), lines: lines + overflow.to_a)
        end

        def next_seq = @monitor.synchronize { @seq += 1 }

        def event_key(payload) = "subagent.#{payload[:storage_id].to_s.empty? ? payload[:id] : payload[:storage_id]}.#{payload[:state]}"

        def fetch_cfg(key, default)
          @config.respond_to?(:fetch) ? @config.fetch(key, default) : default
        end
      end
    end
  end
end
