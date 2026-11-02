# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../storage/vakanuvis"
require_relative "../tools/builtins/storage"
require_relative "../tools/builtins/vakanuvis"

module Rubik
  module Benchmark
    # Vakanüvis araç-benimseme senaryosu (issue #338): küçük modellerin
    # vakanüvis'i ne sıklıkla, nasıl kullandığını ölçen taban çizgisi.
    # "Bu düzeltme iğneyi hareket ettirdi mi?" sorusunun cevabı için
    # prompt-doktrin / yönelim-enjeksiyonu / otomatik-damıtma düzeltmeleri
    # ÖNCE bu ölçüm ister.
    #
    #   Düzlem 1 (deterministik, CI-güvenli): tohum depo + ReplayDriver —
    #   üç davranış profili GERÇEK araç düzlemini çalıştırır (script'lenmiş
    #   araç çağrıları, sahte sonuçlar değil); metrik borusu ve recall
    #   çıktı biçimi regresyona girerse burada patlar.
    #   Düzlem 2 (canlı): LiveDriver provider.complete döngüsü — MODELS
    #   env'i ile model başına gerçek benimseme ölçümü.
    #
    # Sessizlik: canlı modeller maliyetli ve deterministik değildir — bu
    # yüzden default Düzlem 1'dir; rake bench ana süitine asla canlı çağrı
    # sızdırmaz (bench:vakanuvis_adoption MODELS=... açık istek ister).
    module VakanuvisAdoption
      # Tohum kartlar: TR/EN karışık, Keywords: satırlı/satırsız — issue
      # senaryosunun ta kendisi. Görev-1 kartının ayırt edici değerleri
      # (8 saniye adımı + 5 deneme) yanıt-kullanımını dürüstçe sayılabilir
      # kılar: model hatırladığı karttan alıntıladıysa ikisi de görünür.
      SEED_CARDS = [
        {
          topic: "Ağ geçidi yeniden deneme politikası",
          body: "Ağ geçidi 429/503 yanıtında üstel geri çekilme uygular: 2s, 4s, 8s " \
                "(en fazla 5 deneme). Devre kesici 30 ardışık hata sonra açılır.\n" \
                "Keywords: gateway retry backoff üstel geri çekilme 429 503 circuit breaker exponent"
        },
        {
          topic: "Sandbox filesystem allowlist",
          body: "The container sandbox mounts the worktree read-write and $HOME read-only; " \
                "the allowlist file is sandbox.allow at the repo root.\n" \
                "Keywords: sandbox allowlist container readonly mount worktree izin listesi"
        },
        {
          topic: "Vakanüvis damıtma kapısı",
          body: "Damıtma kapısı aynı hedefli işi yutar (dedupe); maksimum kuyruk 8 iş, " \
                "hedef başına tek iz."
        },
        {
          topic: "Fiber scheduler budget",
          body: "The fiber scheduler caps concurrent subagent fibers at 12; overflow " \
                "queues FIFO and never drops."
        },
        {
          topic: "Goal sıra türetimi",
          body: "Goal sırası mağazadaki en büyük annal.goal.N'den türetilir; duvar saati " \
                "ASLA kullanılmaz — kronik MARKER-ZIKKIM-7 determinizmi budur."
        }
      ].freeze

      # Görev 1 yanıt izleri: karttan alıntı → ikisi de eşleşir; uydurma
      # yanıt → en az biri (genelde ikisi) kaçar.
      ANSWER_MARKER_BACKOFF = /8\s*(s\b|sn|sec|second|saniye)/i
      ANSWER_MARKER_TRIES = /(5|beş|five)\s*(deneme|attempt|retr|try)/i

      TASKS = [
        {
          id: "recall-tr-en",
          prompt: "Bu sorunun cevabı rubik://storage kronikçisindeki bir hafıza kartında duruyor: " \
                  "ağ geçidi (gateway) 429/503 yanıtında yeniden deneme / geri çekilme politikası nedir? " \
                  "Kısa cevabını ver."
        },
        {
          id: "durable-conclusion",
          prompt: "We just concluded that the chronicler's digest gate deduplicates jobs for the " \
                  "same target. Persist this durable conclusion so future sessions can recall it, " \
                  "then confirm in one line."
        }
      ].freeze

      MAX_TURNS = 8
      REPLAY_PROFILES = ["adopter", "wrong-path", "struggler"].freeze

      module_function

      # ---- mağaza + araç masası ---------------------------------------------

      # Kronikçi yapılandırması: damıtıcı KAPALI (bench'te asla LLM doğumu —
      # ölçtüğümüz şey maestro davranışı, damıtıcı maliyeti değil).
      class QuietConfig
        def fetch(key, default = nil)
          return false if key == "subagents.vakanuvis.distiller"

          default
        end
      end

      # Deterministik tohum: aynı kart dizisi ⇒ aynı mağaza ⇒ aynı recall
      # davranışı. Her model/profil ÖZGÜN kök dizinle başlar (record
      # yan etkileri bir sonraki modelin ölçümünü kirletmesin).
      def seed_store(root)
        store = Rubik::Storage::Store.new(root: root, project: "vakanuvis-adoption-bench")
        harness = Rubik::Storage::Vakanuvis::Harness.new(store: store, config: QuietConfig.new, session_slug: "bench-seed")
        SEED_CARDS.each { |card| harness.record(topic: card[:topic], body: card[:body]) }
        harness.shutdown
        store
      end

      # İki gerçek yerleşik araç: vakanüvis (doğru yol) + storage (yanlış
      # yolun mümkün olması için masada DURMALI — yoksa yanlış-yol oranı
      # ölçülemez, sahte sıfır doğardı).
      class ToolBench
        def initialize(store, harness)
          @tools = {
            "vakanuvis" => Rubik::Tools::VakanuvisTool.new(harness),
            "storage" => Rubik::Tools::StorageTool.new(store)
          }
        end

        def execute(name, args)
          tool = @tools[name.to_s]
          return "Unknown tool '#{name}' (bench toolbelt: vakanuvis, storage)." unless tool

          tool.execute(args || {})
        rescue StandardError => e
          "tool error: #{e.class}: #{e.message}"
        end

        def schemas = @tools.values.map(&:to_h)
      end

      # ---- sürücüler --------------------------------------------------------
      # Sözleşme: run_task(task, tools) -> { turns:, answer:, calls:,
      # first_recall_turn:, hit_cap: }. calls = [[name, args, result_text]]
      # (sıralı). first_recall_turn = ilk recall'in 1-tabanlı turn'ü.

      # Script'lenmiş davranış profilleri — scriptler GERÇEK araçlarla
      # koşar (sonuç sahtelenmez); metrik borusunun deterministik kanıtı.
      class ReplayDriver
        attr_reader :profile

        def initialize(profile)
          @profile = profile.to_s
        end

        def label = "scripted/#{@profile}"

        def live? = false

        def run_task(task, tools)
          calls = []
          answer = ""
          turns = 0
          first_recall_turn = nil
          SCRIPTS.fetch(@profile).fetch(task[:id]).each do |step|
            turns += 1
            steps = step[:call] ? [step[:call]] : (step[:call_each] || [])
            steps.each do |name, args|
              first_recall_turn ||= turns if recall_step?(name, args)
              calls << [name, args, tools.execute(name, args)]
            end
            answer = step[:answer] if step.key?(:answer)
          end
          { turns: turns, answer: answer, calls: calls, first_recall_turn: first_recall_turn, hit_cap: false }
        end

        private

        def recall_step?(name, args)
          name == "vakanuvis" && (args["action"].nil? || args["action"] == "recall")
        end
      end

      # Canlı sürücü: provider.complete döngüsü. Prompt görevi söyletir,
      # araç seçimini ASLA emretmez — benimseme ölçümünün koşulu budur.
      class LiveDriver
        def initialize(provider, max_turns: MAX_TURNS)
          @provider = provider
          @max_turns = max_turns
        end

        def label = "live/#{@provider.name}/#{@provider.model}"

        def live? = true

        def run_task(task, tools)
          history = [{ "role" => "user", "content" => task[:prompt] }]
          calls = []
          turns = 0
          first_recall_turn = nil
          answer = ""

          @max_turns.times do
            turns += 1
            res = @provider.complete(history, { tools: tools.schemas })
            # Sağlayıcı sözleşmesi (inceleme turu 2): Response dışı bir
            # dönüş, respond_to? zincirlerine girip sahte "araç
            # benimsemedi / tur sınırına vurdu" veri noktası üretmesin —
            # dürüstçe patla.
            raise "provider returned #{res.inspect}, expected Rubik::LLM::Response" unless res.is_a?(Rubik::LLM::Response)

            tool_calls = res.respond_to?(:tool_calls?) && res.tool_calls? ? res.tool_calls : []
            if tool_calls.empty?
              answer = res.respond_to?(:text) ? res.text.to_s : res.to_s
              break
            end

            history << {
              role: "assistant",
              content: res.respond_to?(:text) ? res.text.to_s : "",
              tool_calls: tool_calls.map { |tc| { "id" => tc["id"], "tool" => tc["tool"], "args" => tc["args"] } }
            }
            tool_calls.each do |tc|
              args = tc["args"].is_a?(Hash) ? tc["args"] : {}
              action = args["action"].to_s
              first_recall_turn ||= turns if tc["tool"] == "vakanuvis" && (action.empty? || action == "recall")
              result = tools.execute(tc["tool"], args)
              calls << [tc["tool"], args, result]
              history << { role: "tool", tool_call_id: tc["id"], tool_name: tc["tool"], content: result.to_s }
            end
          end

          { turns: turns, answer: answer, calls: calls, first_recall_turn: first_recall_turn, hit_cap: answer.empty? }
        end
      end

      # ---- metrikler --------------------------------------------------------

      Metrics = Struct.new(
        :label, :recall_called, :first_recall_turn, :recall_calls, :avg_query_terms,
        :keywords_line_used, :recall_empty_rate, :record_called, :wrong_path_puts,
        :answer_used_recall, :hit_turn_cap, keyword_init: true
      ) do
        def summary
          "recall=#{recall_called ? "turn #{first_recall_turn}" : 'never'} calls=#{recall_calls} " \
            "terms=#{avg_query_terms || '-'} kw=#{keywords_line_used ? 'yes' : 'no'} empty=#{recall_empty_rate || '-'}% " \
            "record=#{record_called ? 'vakanuvis' : 'none'} wrong_put=#{wrong_path_puts} " \
            "answer_used=#{answer_used_recall ? 'yes' : 'no'}"
        end
      end

      def metrics_for(label, task_runs)
        recall_events = []
        record_calls = 0
        wrong_puts = 0
        first_recall_turn = nil
        answer_used = false
        hit_cap = false

        task_runs.each do |run|
          run[:calls].each do |name, args, result|
            if name == "vakanuvis"
              action = args["action"].to_s
              if action.empty? || action == "recall"
                recall_events << [args["query"].to_s, result.to_s]
                first_recall_turn ||= run[:first_recall_turn]
              elsif action == "record"
                record_calls += 1
              end
            elsif name == "storage" && args["action"].to_s == "put" && ["memory", "wiki"].include?(args["type"].to_s)
              wrong_puts += 1 # kronikçi masada DURUYORKEN doğrudan put = yanlış yol
            end
          end
          answer_used ||= answer_uses_recall?(run[:answer])
          hit_cap ||= run[:hit_cap] == true
        end

        terms = recall_events.map { |query, _res| query.strip.split(/\s+/).reject(&:empty?).size }
        Metrics.new(
          label: label,
          recall_called: !recall_events.empty?,
          first_recall_turn: first_recall_turn,
          recall_calls: recall_events.size,
          avg_query_terms: terms.empty? ? nil : terms.sum.fdiv(terms.size).round(1),
          keywords_line_used: recall_events.any? { |query, _res| query.include?("Keywords:") },
          recall_empty_rate: recall_events.empty? ? nil : empty_rate(recall_events),
          record_called: record_calls.positive?,
          wrong_path_puts: wrong_puts,
          answer_used_recall: answer_used,
          hit_turn_cap: hit_cap
        )
      end

      # "Recalled N ..." başlığı dışındaki her şey (anahtar-AND boş + yalnız
      # fallback izleri) boş sayılır — issue'nin "fallback dahil" tanımı.
      def empty_rate(recall_events)
        empty_count = recall_events.count { |_query, res| !res.start_with?("Recalled ") }
        (empty_count.fdiv(recall_events.size) * 100).round(0)
      end

      def answer_uses_recall?(text)
        text = text.to_s
        text.match?(ANSWER_MARKER_BACKOFF) && text.match?(ANSWER_MARKER_TRIES)
      end

      # ---- koşu -------------------------------------------------------------

      # Her sürücü özgün tohumlu mağaza alır (izolasyon: record yan
      # etkileri sızamaz). Sürücü hatası TEK modeli tablodan düşürür —
      # diğer modellerin ölçümü yaşamaya devam eder; düşen satır sınıfa
      # göre ayrışır: RateLimitError → SkipRow (kota/ağ ölümü — geçici),
      # diğer her şey → ErrorRow (kimlik doğrulama, bozuk JSON, determin-
      # istik düzlemde script hatası... bunlar "skipped" kıyafetini taşımaya
      # değmez). Deterministik düzlemde çöküş loud: diğer bench metotları
      # gibi rake bench'i kırmalı — çökme "skipped" diye kaydedilmez.
      def run(drivers, io: $stdout)
        drivers.map do |driver|
          root = Dir.mktmpdir("rubik_vakanuvis_adoption")
          begin
            store = seed_store(root)
            harness = Rubik::Storage::Vakanuvis::Harness.new(store: store, config: QuietConfig.new, session_slug: "bench-#{driver.label}")
            tools = ToolBench.new(store, harness)
            runs = TASKS.map { |task| driver.run_task(task, tools) }
            tool_errors = runs.sum { |r| r[:calls].count { |_n, _a, res| TOOL_ERROR_MARKERS.any? { |m| res.to_s.start_with?(m) } } }
            if tool_errors.positive?
              first_bad = runs.flat_map { |r| r[:calls] }.find { |_n, _a, res| TOOL_ERROR_MARKERS.any? { |m| res.to_s.start_with?(m) } }
              raise "#{driver.label}: #{tool_errors} tool error(s) — the bench toolbelt itself failed; " \
                    "these numbers would read as model behavior. first: #{first_bad[2].to_s[0, 160]}"
            end
            harness.shutdown
            metrics_for(driver.label, runs).tap { |m| io&.puts("  [vakanuvis-adoption] #{m.label}: #{m.summary}") }
          rescue Rubik::LLM::RateLimitError => e
            location = (e.backtrace || []).first
            io&.puts("  [vakanuvis-adoption] #{driver.label}: SKIPPED (rate limited) — #{e.message} @ #{location}")
            SkipRow.new(driver.label, e)
          rescue Rubik::LLM::ClientError, StandardError => e
            # Deterministik düzlem: asla satıra dönüşmesin (rake bench
            # loud patlar). Canlı düzlem: tek bozuk sürücü kalan modellerin
            # ölçümünü öldürmesin — dürüst ERROR satırı düşer.
            raise unless driver.live?

            location = (e.backtrace || []).first
            io&.puts("  [vakanuvis-adoption] #{driver.label}: ERROR — #{e.class}: #{e.message} @ #{location}")
            ErrorRow.new(driver.label, e)
          ensure
            begin
              FileUtils.remove_entry(root)
            rescue StandardError => e
              # Windows EBUSY/ENOTEMPTY (AV tarayıcı, indeksleyici) cleanup'ı
              # patlatabilir — cleanup hatası tabloyu ve işlenen hatayı
              # MaskeleMEsin; tüm benchmark'ı da abort etmesin.
              warn "  [vakanuvis-adoption] cleanup failed for #{root}: #{e.class}: #{e.message}"
            end
          end
        end
      end

      # Kota/ağ ölümü yaşayan modelin tablo satırı: yok saymak değil —
      # "ölçülemedi"yi tabloda göster (sessiz-satır-kaybı yok).
      SkipRow = Struct.new(:label, :error) do
        def summary = "skipped: #{error.class}: #{error.message.to_s[0, 120]}"
      end

      # Kota DEĞİL — kimlik doğrulama, bozuk sağlayıcı yanıtı, kabuk...
      # "skipped" yalan olur; tabloda error diye ayrışır.
      ErrorRow = Struct.new(:label, :error) do
        def summary = "error: #{error.class}: #{error.message.to_s[0, 120]}"
      end

      # Bench tarafı araç hataları (ToolBench#execute'un kurtarma dizgileri):
      # bunlar model davranışı DEĞİL — metrik borusuna girmeden yakalanır.
      TOOL_ERROR_MARKERS = ["tool error: ", "Unknown tool "].freeze

      # Metrik satırlarından runner sonuçları: hedef taban çizgisi (model
      # puanı değil — senaryo KOŞTU mu). Tablo io'ya markdown düşer.
      def metric_results(rows, io: $stdout)
        io&.puts("\n#### Vakanüvis tool adoption (issue #338)\n")
        io&.puts("| model | recall | first@ | calls | terms | kw:line | empty% | record | wrong put | answer used |")
        io&.puts("|---|---|---|---|---|---|---|---|---|---|")
        rows.map do |m|
          if m.is_a?(SkipRow) || m.is_a?(ErrorRow)
            # Ölçülemeyen model tabloda KALIR — satır kaybı sessiz değil;
            # kota ölümü (skipped) ile gerçek hata (error) ayrışır.
            status = m.is_a?(SkipRow) ? "skipped" : "error"
            # 10 hücre: başlık 10 sütun — 11. hücreye düşen skip/error
            # gerekçesi GFM tarafından SESSİZCE düşürülüyordu.
            io&.puts("| #{m.label} | #{status} | - | - | - | - | - | - | - | (#{m.summary}) |")
            next Rubik::Benchmark::MetricResult.new(
              name: "Vakanüvis Tool Adoption — #{m.label}",
              target: "baseline (issue #338)",
              measured: m.summary,
              passed: false
            )
          end
          io&.puts("| #{m.label} | #{m.recall_called ? 'yes' : 'NO'} | #{m.first_recall_turn || '-'} | #{m.recall_calls} | " \
                   "#{m.avg_query_terms || '-'} | #{m.keywords_line_used ? 'yes' : 'no'} | #{m.recall_empty_rate || '-'}% | " \
                   "#{m.record_called ? 'vakanuvis' : 'none'} | #{m.wrong_path_puts} | #{m.answer_used_recall ? 'yes' : 'no'} |")
          Rubik::Benchmark::MetricResult.new(
            name: "Vakanüvis Tool Adoption — #{m.label}",
            target: "baseline (issue #338)",
            measured: m.summary,
            passed: true
          )
        end
      end

      # Replay script'leri: her adım {call: [name, args]} | {call_each: [[name,
      # args], ...]} | {answer: "..."} — ReplayDriver bunları GERÇEK
      # araçlarla sırayla koşturur; yanıtlar profilin davranış taahhüdüdür.
      SCRIPTS = {
        "adopter" => {
          "recall-tr-en" => [
            { call: ["vakanuvis", { "action" => "recall", "query" => "gateway retry backoff 429" }] },
            { answer: "Üstel geri çekilme: 2s, 4s, 8s — en fazla 5 deneme; 30 ardışık hata sonra devre kesici açılır." }
          ],
          "durable-conclusion" => [
            { call: ["vakanuvis", { "action" => "record", "topic" => "digest gate dedupe",
                                    "body" => "Same-target digest jobs are deduplicated; queue cap is 8 jobs, one in-flight per target.\n" \
                                              "Keywords: digest dedupe gate queue target" }] },
            { answer: "Recorded as a memory card via the chronicler." }
          ]
        },
        "wrong-path" => {
          "recall-tr-en" => [
            { answer: "Bilmiyorum; geçidi yeniden dene ve sonra tekrar sor." }
          ],
          "durable-conclusion" => [
            { call_each: [["storage", { "action" => "put", "type" => "memory", "title" => "digest dedupe",
                                        "body" => "Same-target digest jobs are deduplicated." }]] },
            { answer: "Persisted directly to storage." }
          ]
        },
        "struggler" => {
          "recall-tr-en" => [
            { call: ["vakanuvis", { "action" => "recall", "query" => "gateway hangi durumlarda üstel bekleme uygular ve devre kesici kaç hata sonra açılır" }] },
            { call: ["vakanuvis", { "action" => "recall", "query" => "gateway retry backoff" }] },
            { answer: "2s, 4s, 8s üstel geri çekilme uygulanır (en fazla 5 deneme)." }
          ],
          "durable-conclusion" => [
            { call: ["vakanuvis", { "action" => "record", "topic" => "digest gate dedupe",
                                    "body" => "Same-target digest jobs are deduplicated." }] },
            { answer: "Saved via vakanuvis record." }
          ]
        }
      }.freeze
    end
  end
end
