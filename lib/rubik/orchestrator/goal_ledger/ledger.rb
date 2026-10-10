# frozen_string_literal: true

require "time"
require "json"
require_relative "../../prompt/context_compactor"
require_relative "../../prompt/conversation_rows"
require_relative "../../uris"

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

        # A planı üretim şemasını SAHİPLENİR: goal skeleton örnek örneği
        # üretim yüzeyi olur (frozen; verify alanları optional+allow_null —
        # re-verification planı doldurur).
        PRODUCTION_SCHEMA = Schema.goal_skeleton

        attr_reader :rev

        def initialize(goal_text:, max_retries: DEFAULT_MAX_RETRIES, store: nil, dmesg: nil)
          @monitor = Monitor.new
          @max_retries = max_retries.to_i
          @store = store
          @dmesg = dmesg
          @rejections = 0
          @storage_id = nil
          @last_links = {}
          @finalized = false
          @updated_at = nil
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

          def max_patch_retries(config = nil)
            config_get(config, "goal.ledger.max_patch_retries", DEFAULT_MAX_RETRIES).to_i
          end

          def create!(goal_text:, config: nil, store: nil, dmesg: nil)
            ledger = new(goal_text: goal_text.to_s, max_retries: max_patch_retries(config),
                         store: store, dmesg: dmesg)
            ledger.persist_seed!
            ledger
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
            history.reject! { |msg| ledger_row?(msg) }
            row = { role: "user", content: render_xml }
            anchor = history.rindex { |msg| Prompt::ContextCompactor.goal_message?(msg) }
            anchor ? history.insert(anchor + 1, row) : history << row
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
            end
            log(:finalized, "goal ledger finalized at rev #{@doc['rev']} (status: #{status})")
            final_result
          end
        rescue StandardError => e
          degrade("final status stamp", e)
          @monitor.synchronize { final_result }
        end

        def to_xml
          @monitor.synchronize { render_xml }
        end

        # §4.1 render: GoalState#to_xml mold'u — tüm metin xml_escape'ten
        # geçer; boş koleksiyonların etiketi HİÇ basılmaz ("yokluk, boşluk
        # değil" kuralı); optional attribute'lar (storage_id, verify) yalnız
        # set iken basılır.
        def render_xml
          esc = Rubik::Platform.method(:xml_escape)
          attrs = %(rev="#{@doc['rev']}")
          attrs += %( storage_id="#{esc.call(@storage_id)}") if @storage_id
          attrs += %( updated_at="#{@updated_at.utc.iso8601}") if @updated_at
          body = []
          body << %(  <objective>#{esc.call(@doc['objective'].to_s)}</objective>)
          tasks = @doc["tasks"].map do |task|
            text = task["title"].to_s
            text += " — notes: #{task['notes']}" if task["notes"]
            attrs_t = %(id="#{esc.call(task['id'].to_s)}" status="#{esc.call(task['status'].to_s)}")
            attrs_t += %( verify="#{esc.call(task['verify'].to_s)}") if task["verify"]
            task["title"] || task["notes"] ? %(  <task #{attrs_t}>#{esc.call(text)}</task>) : %(  <task #{attrs_t} />)
          end
          body << "<tasks>\n#{tasks.join("\n")}\n  </tasks>" unless tasks.empty?
          findings = @doc["findings"].map do |f|
            %(  <finding id="#{esc.call(f['id'].to_s)}" source_step="#{f['source_step']}">#{esc.call(f['text'].to_s)}</finding>)
          end
          body << "<findings>\n#{findings.join("\n")}\n  </findings>" unless findings.empty?
          decisions = @doc["decisions"].map do |dec|
            attrs_d = %(id="#{esc.call(dec['id'].to_s)}")
            attrs_d += %( rationale="#{esc.call(dec['rationale'].to_s)}") if dec["rationale"]
            %(  <decision #{attrs_d}>#{esc.call(dec['text'].to_s)}</decision>)
          end
          body << "<decisions>\n#{decisions.join("\n")}\n  </decisions>" unless decisions.empty?
          questions = @doc["open_questions"].map { |q| %(  <question>#{esc.call(q.to_s)}</question>) }
          body << "<open_questions>\n#{questions.join("\n")}\n  </open_questions>" unless questions.empty?
          notes = @doc["environment_notes"].map do |note|
            attrs_n = %(id="#{esc.call(note['id'].to_s)}")
            attrs_n += %( verify="#{esc.call(note['verify'].to_s)}") if note["verify"]
            %(  <note #{attrs_n}>#{esc.call(note['text'].to_s)}</note>)
          end
          body << "<environment_notes>\n#{notes.join("\n")}\n  </environment_notes>" unless notes.empty?
          <<~XML.strip
            <goal_ledger #{attrs}>
            #{body.join("\n")}
            </goal_ledger>
          XML
        end

        def snapshot
          @monitor.synchronize do
            { rev: @doc["rev"], objective: @doc["objective"], storage_id: @storage_id,
              updated_at: @updated_at, finalized: @finalized, tasks: @doc["tasks"].size,
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
          @doc = new_doc
          @rejections = 0
          @updated_at = Time.now.utc
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

        def log(event, message)
          return unless @dmesg.respond_to?(:log)

          @dmesg.log(:goal_ledger, :info, "[#{event}] #{message}")
        rescue StandardError
          Rubik::Log.warn(:goal_ledger, "[#{event}] #{message}")
        end

        def degrade(what, error)
          Rubik::Log.warn(:goal_ledger, "goal ledger #{what} unavailable (#{error.class}: #{error.message}); " \
                                        "Σ continues in memory")
        end
      end
    end
  end
end
