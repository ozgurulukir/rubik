# frozen_string_literal: true

require "time"
require "json"
require_relative "../../prompt/context_compactor"
require_relative "../../prompt/conversation_rows"
require_relative "../../uris"
require_relative "suspend_lifecycle"
require_relative "xml_render"

module Rubik
  module Orchestrator
    module GoalLedger
      # !goal döngüsünün yapılandırılmış ΔΣ defteri (Σ) — SKILL.state
      # uyarlamasının durumlu yarısı. C kütüphanesi (Patch/Schema/Validator)
      # SAFTI; burada yaşam döngüsü durumu yaşar: Monitor korumalı doküman,
      # ardışık-ret bütçesi, storage revizyon zinciri (her kabul YENİ satır;
      # `goal-ledger` ref'i daima son revizyonu gösterir) ve dmesg telemetrisi.
      #
      # Thread modeli (plan A kuralı): yazmalar YALNIZ turn thread'indedir
      # (araç execute, step-top refresh, finalize); tüm okumalar Monitor
      # altındadır — rubik://goal/ledger read_file her an güvenlidir
      # (GoalState mold'u). Arkaplan thread'i yoktur.
      #
      # Degradasyon sözleşmesi: Store yoksa/başarısızsa satır YAZILMAZ, tek
      # dmesg warn düşer ve Σ bellekte yaşamaya devam eder — özellik asla
      # storage hatasıyla çökmez ("prompt'tan atmak ≠ kayıttan atmak":
      # transcripts/ToolHistory bu sınıfa hiç girmez).
      class Ledger
        Result = Struct.new(:status, :reasons, :rev, :uri, keyword_init: true)

        # Askı yaşam döngüsü (issue #106): suspend!/unsuspend! damgaları +
        # restore_from_row! + suspend_meta — instance-method include ile
        # private yardımcılara (row_title, canonical_json, final_result,
        # log, degrade) doğal erişir. Σ XML render yüzeyi XmlRender'da.
        include SuspendLifecycle
        include XmlRender

        # A planı üretim şemasını SAHİPLENİR: goal skeleton örnek örneği
        # üretim yüzeyi olur (frozen; verify alanları optional+allow_null —
        # re-verification planı doldurur).
        PRODUCTION_SCHEMA = Schema.goal_skeleton

        # rev = Σ sürüm SSOT'u (doc["rev"]) — ObservationProjection ve
        # kullanıcılar Monitor altında okur (@rev ivarı YOKTUR; atanmaz).
        def rev
          @monitor.synchronize { @doc["rev"] }
        end

        attr_reader :event_bus

        def initialize(goal_text:, max_retries: DEFAULT_MAX_RETRIES, store: nil, dmesg: nil, event_bus: nil)
          @monitor = Monitor.new
          @max_retries = max_retries.to_i
          @store = store
          @dmesg = dmesg
          @event_bus = event_bus
          @rejections = 0
          @storage_id = nil
          @last_links = {}
          @finalized = false
          @updated_at = nil
          @last_drift_note = nil
          @suspend_meta = nil
          @doc = seed_doc(goal_text)
        end

        # ------------------------------------------------------------------
        # Sınıf yüzü: çift-diyalekt knob okuması (pruner Service mold'u —
        # Rubik::Config dotted-path böler, düz Hash tek anahtar sayar) ve
        # oluşturma fabrikası. Konum: Ledger üzerinde, çünkü GoalLedger
        # modülü C sabitlerinin evi olmayı sürdürür (shim < 90 hygiene pin).
        class << self
          def enabled?(config = nil)
            config_get(config, "goal.ledger.enabled", true)
          end

          # B'nin knob'u (re-verification): enabled kapalıyken İNERTTİR
          # (coeffect hiç provide edilmez → verifier girişi no-op).
          def verify_enabled?(config = nil)
            config_get(config, "goal.ledger.verify", true)
          end

          def max_patch_retries(config = nil)
            config_get(config, "goal.ledger.max_patch_retries", DEFAULT_MAX_RETRIES).to_i
          end

          def create!(goal_text:, config: nil, store: nil, dmesg: nil, event_bus: nil)
            ledger = new(goal_text: goal_text.to_s, max_retries: max_patch_retries(config),
                         store: store, dmesg: dmesg, event_bus: event_bus)
            ledger.persist_seed!
            ledger
          end

          # Çapraz-süreç resume fabrikası — gövde SuspendLifecycle'ta
          # (satır cap'i disiplini; bozuk/askı-olmayan damga → dürüst nil).
          def load(store:, storage_id:, config: nil, dmesg: nil, event_bus: nil)
            SuspendLifecycle.load(store: store, storage_id: storage_id, config: config, dmesg: dmesg, event_bus: event_bus)
          end

          def config_get(config, key, default)
            return default if config.nil?

            val = if config.is_a?(Hash)
                    config.dig(*key.to_s.split("."))
                  elsif config.respond_to?(:fetch)
                    config.fetch(key, nil)
                  end
            val.nil? ? default : val
          end
        end

        def persist_seed!
          row = put_row(title: row_title, body: canonical_json, tags: ["goal-ledger"], links: {}, ref: "goal-ledger")
          @storage_id = row["id"] if row
          degrade_storage_once unless row
        rescue StandardError => e
          degrade("seed revision row", e)
        end

        # Tek giriş: patch metni (ya da Patch VO) → sınıflandırılmış sonuç.
        # Ret sayacı ardışıktır; başarı sıfırlar; bütçe aşımında :exhausted
        # döner ve ESKİ Σ korunur (goal loop asla brick olmaz).
        def update(patch_or_text)
          verdict = Validator.validate(patch_or_text, schema: PRODUCTION_SCHEMA, current_doc: @doc)
          @monitor.synchronize do
            if verdict[0] == :ok
              apply!(verdict[1])
            elsif @rejections >= @max_retries
              # C sözleşmesi: ardışık ret bütçesi dolu — ESKİ Σ korunur ve
              # dürüst tükenme döner; geçerli bir patch geldiğinde kabul
              # yolu yeniden açılır (goal loop asla brick olmaz).
              exhausted_result
            else
              @rejections += 1
              log(:patch_rejected, "patch rejected (#{@rejections}/#{@max_retries} budget): " \
                                   "#{verdict[1].first[:class]} — #{verdict[1].first[:message]}")
              Result.new(status: :rejected, reasons: verdict[1], rev: @doc["rev"], uri: ledger_uri)
            end
          end
        end

        # Adım başı yenileme: mevcut Σ satırlarını düşürüp TEK güncel satırı
        # <user_task> hedef satırının peşine yerleştirir (tek-Σ-satırı
        # invaryantı — pinli satırlar compaction'ı baypas ederek şişemez).
        # Ledger satırı role "user" zorunludur: EmergencyCompactor hard
        # tier'ı user satırlarına dokunmaz (emergency_compactor.rb:59-77).
        def refresh_in_history!(history)
          return if history.nil? || !history.respond_to?(:reject!)

          @monitor.synchronize do
            history.reject! { |msg| ledger_row?(msg) || drift_row?(msg) }
            anchor = history.rindex { |msg| Prompt::ContextCompactor.goal_message?(msg) }
            if anchor
              history.insert(anchor + 1, { role: "user", content: render_xml })
              history.insert(anchor + 2, { role: "user", content: @last_drift_note }) if @last_drift_note
            else
              history << { role: "user", content: render_xml }
              history << { role: "user", content: @last_drift_note } if @last_drift_note
            end
          end
        end

        # Terminal damga (complete!/fail!/stop! sonrası): son revizyon
        # satırına status yazılır (id korunur — version++), idempotenttir.
        def finalize!(status)
          @monitor.synchronize do
            return final_result if @finalized

            @finalized = true
            if @store && @storage_id
              links = @last_links.merge("finish_status" => status.to_s)
              row = @store.put(type: "goal", id: @storage_id, title: row_title, body: canonical_json,
                               tags: ["goal-ledger", "final"], links: links, status: status.to_s)
              @storage_id = row["id"]
            else
              degrade_storage_once
            end
            log(:finalized, "goal ledger finalized at rev #{@doc['rev']} (status: #{status})")
            final_result
          end
        rescue StandardError => e
          degrade("final status stamp", e)
          @monitor.synchronize { final_result }
        end

        # B (re-verification): iç mutasyon girişi — drift flip'leri MODEL
        # ΔΣ validasyonunu ATLAR (bu bir model patch'i değildir) ama rev
        # BUMP EDİLİR: :conflict, drift sinyalinin ta kendisidir (model
        # bayat rev ile patch gönderir → conflict → yeniden okur → stale
        # bayraklarını GÖRÜR — paper'ın zero-recovery mekanizması). Tek
        # yazar disiplini: persistence A'nın kendi put yolundan geçer.
        def apply_internal_drift!(flips)
          @monitor.synchronize do
            flips.each do |flip|
              item = @doc[flip[:collection]]&.[](flip[:index])
              next unless item.is_a?(Hash)

              item["status"] = "stale" if flip[:collection] == "tasks"
              verify_h = item["verify"].is_a?(Hash) ? item["verify"].dup : {}
              verify_h["last_check"] = { "state" => "failed", "from" => flip[:from].to_s,
                                         "reason" => flip[:reason].to_s, "at" => flip[:at].to_s }
              item["verify"] = verify_h
            end
            return nil if flips.empty?

            @doc["rev"] += 1
            @updated_at = Time.now.utc
            if @store && @storage_id
              @store.put(type: "goal", id: @storage_id, title: row_title, body: canonical_json,
                         tags: ["goal-ledger"], links: @last_links, status: "active")
            end
            @last_drift_note = DriftNote.render(snap: deep_dup(@doc))
            log(:ledger_drift, "internal drift applied: #{flips.size} flip(s), rev #{@doc['rev']}")
            { rev: @doc["rev"], flipped: flips.size }
          end
        rescue StandardError => e
          degrade("drift persistence", e)
          nil
        end

        # Verifier girişi: Monitor'lu FROZEN kopya — FS IO kilit dışı
        # değerlendirilir (verifier.rb disiplini).
        def snapshot_doc
          @monitor.synchronize { deep_freeze(deep_dup(@doc)) }
        end

        # Test/seam gözlemcisi: güncel drift notu (yoksa nil).
        def render_drift_note
          @monitor.synchronize { DriftNote.render(snap: deep_dup(@doc)) }
        end

        # (Σ XML render yüzeyi — to_xml / render_xml — XmlRender sayfası.)

        def snapshot
          @monitor.synchronize do
            { rev: @doc["rev"], objective: @doc["objective"], storage_id: @storage_id,
              updated_at: @updated_at, finalized: @finalized,
              suspended: @suspend_meta.is_a?(Hash) && !@finalized,
              suspend_meta: @suspend_meta ? deep_dup(@suspend_meta) : nil,
              tasks: @doc["tasks"].size,
              findings: @doc["findings"].size, decisions: @doc["decisions"].size,
              open_questions: @doc["open_questions"].size, environment_notes: @doc["environment_notes"].size }
          end
        end

        private

        def seed_doc(goal_text)
          { "rev" => 0, "objective" => Rubik::Platform.safe_utf8(goal_text.to_s.slice(0, 400)),
            "tasks" => [], "findings" => [], "decisions" => [],
            "open_questions" => [], "environment_notes" => [] }
        end

        def apply!(new_doc)
          # Validator deep-frozen çıkarır (VO sözleşmesi); durum sahibi
          # ledger'ın ÇALIŞMA kopyası mutable kalmalıdır (apply_internal_drift!
          # ve render_xml iç mutasyonu).
          @doc = deep_dup(new_doc)
          @rejections = 0
          @updated_at = Time.now.utc
          @last_drift_note = nil # model yeniden planladı — drift notu tek seferliktir
          links = @storage_id ? { "ledger_prev" => @storage_id } : {}
          row = put_row(title: row_title, body: canonical_json, tags: ["goal-ledger"], links: links, ref: "goal-ledger")
          if row
            @storage_id = row["id"]
            @last_links = links
          end
          log(:patch_accepted, "goal ledger rev #{@doc['rev']} applied (#{row ? "stored #{@storage_id}" : 'memory-only'})")
          Result.new(status: :applied, rev: @doc["rev"], uri: ledger_uri)
        rescue StandardError => e
          # Storage yazım başarısızlığı araç yolunu BOGMAMALI: Σ zaten
          # uygulandı (atomik validate-then-apply), yalnız kalıcılık düştü.
          degrade("revision row", e)
          Result.new(status: :applied, rev: @doc["rev"], uri: ledger_uri)
        end

        def exhausted_result
          log(:patch_exhausted, "patch budget exhausted after #{@rejections} consecutive rejections; " \
                                "ledger unchanged at rev #{@doc['rev']}")
          Result.new(status: :exhausted, rev: @doc["rev"], uri: ledger_uri)
        end

        def final_result
          { id: @storage_id, rev: @doc["rev"], uri: ledger_uri }
        end

        def put_row(title:, body:, tags:, links:, ref: nil)
          return nil unless @store

          @store.put(type: "goal", title: title, body: body, tags: tags, links: links, ref: ref)
        end

        def canonical_json
          Rubik::Platform.safe_json_generate(@doc)
        end

        def row_title
          "ledger r#{@doc['rev']}: #{Rubik::Platform.safe_utf8(@doc['objective'].to_s.slice(0, 60))}"
        end

        def ledger_uri
          @storage_id ? Rubik::Uris.storage_entity(project: @store.project, type: "goal", id: @storage_id) : nil
        end

        def ledger_row?(msg)
          return false unless Prompt::ConversationRows.row?(msg)

          content = Prompt::ConversationRows.content_of(msg).to_s
          Prompt::ConversationRows.role_of(msg) == "user" && content.start_with?("<goal_ledger ") && content.include?("</goal_ledger>")
        end

        def drift_row?(msg)
          return false unless Prompt::ConversationRows.row?(msg)

          content = Prompt::ConversationRows.content_of(msg).to_s
          Prompt::ConversationRows.role_of(msg) == "user" && content.start_with?("<ledger_drift ") && content.include?("</ledger_drift>")
        end

        def deep_dup(value)
          case value
          when Hash then value.to_a.to_h { |key, val| [key.dup, deep_dup(val)] }
          when Array then value.map { |val| deep_dup(val) }
          else value
          end
        end

        def deep_freeze(value)
          case value
          when Hash then value.each do |key, val|
            deep_freeze(key)
            deep_freeze(val)
          end.freeze
          when Array then value.each { |val| deep_freeze(val) }.freeze
          when String then value.dup.freeze
          else value
          end
        end

        def log(event, message)
          unless @dmesg.respond_to?(:log)
            # Dürüst degradasyon (review 2026-10-10): dmesg yokken telemetri
            # sessizliğe gömülmesin — bir kez Log'a düş, sonra sessiz.
            unless @dmesg_degraded
              @dmesg_degraded = true
              Rubik::Log.warn(:goal_ledger, "dmesg unavailable — goal ledger telemetry degraded to Log only")
            end
            return
          end

          @dmesg.log(:goal_ledger, :info, "[#{event}] #{message}")
        rescue StandardError
          Rubik::Log.warn(:goal_ledger, "[#{event}] #{message}")
        end

        def degrade(what, error)
          Rubik::Log.warn(:goal_ledger, "goal ledger #{what} unavailable (#{error.class}: #{error.message}); " \
                                        "Σ continues in memory")
        end

        # Depo yokluğu bilinçli degradasyondur ama SESSIZ olamaz (sözleşme:
        # tek dürüst warn) — memoize'lı tek atış.
        def degrade_storage_once
          return if @storage_degraded

          @storage_degraded = true
          Rubik::Log.warn(:goal_ledger, "storage unavailable — goal ledger revisions stay memory-only (no audit rows)")
        end
      end
    end
  end
end
