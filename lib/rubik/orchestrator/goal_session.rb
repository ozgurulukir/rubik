# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "../log"
require_relative "../platform"
require_relative "goal_state"
require_relative "goal_registry"
require_relative "goal_ledger"

module Rubik
  module Orchestrator
    # Goal-session domain (issue #404): the ONE home for the !goal run
    # lifecycle — start (execute_goal), the shared turn driver
    # (drive_goal_turn: budget extensions, the single error channel,
    # terminal mapping), suspension plus both resume paths (in-process
    # loop revival and cross-process Σ-window rehydration), the suspended
    # -goal registry plumbing and the `!goal list` surface. Moved verbatim
    # from REPL::Commands::AgentExecution; the command block keeps only
    # argument parsing and delegates here.
    #
    #   owns   : goal start/suspend/resume/fail/complete choreography, the
    #            GoalState + Σ ledger + registry provide discipline, the
    #            honest-continuity output strings, the documented ordering
    #            contracts (ledger_id-before-suspend!, suspend_stamp_meta
    #            schema), the shared resume tail (resume_drive) and the
    #            goal-shaped orchestrator-loop stanza (build_goal_orchestrator)
    #   leaves : command argument parsing and usage rendering
    #            (REPL::Commands::AgentExecution), the Loop machinery
    #            itself (Loop/GoalWait), and input_execution's streaming
    #            on_step stanza
    module GoalSession
      module_function

      def initialize_goal_ledger(ctx, goal_text)
        return nil unless Rubik::Orchestrator::GoalLedger::Ledger.enabled?(ctx.config)

        store = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::STORAGE_STORE)
        dmesg = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::DMESG)
        goal_ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(
          goal_text: goal_text, config: ctx.config, store: store, dmesg: dmesg,
          event_bus: ctx.event_bus
        )
        ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_LEDGER, goal_ledger)
        goal_ledger
      end

      def execute_goal(ctx, goal_text, custom_steps)
        ctx.recorder&.record_user_turn("!goal #{goal_text}")
        goal_steps = custom_steps || ctx.config.fetch("agent.goal_max_steps", 100).to_i
        routed = ctx.router.route(task_type: :goal, prompt: goal_text)
        ctx.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]

        # Canlı hedef durumu: maestro ve alt ajanlar read_file
        # rubik://goal/state ile aynı anlık görüntüyü okur. Provide swap
        # semantiğine sahiptir — tekrarlanan !goal koşuları Ω'ya inverse
        # yığmaz; session dispose'u tek delete-inverse ile temizler.
        # event_bus: bitiş olayı (GoalState::FINISH_EVENT) Vakanüvis
        # kronikçisinin goal kancasına akar (K3) — notice/wake yok.
        goal_state = Rubik::Orchestrator::GoalState.new(event_bus: ctx.event_bus)
        goal_state.start!(goal_text, goal_steps)
        ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_STATE, goal_state)

        # Yapılandırılmış Σ defteri (goal-ledger planı A): knob ON iken
        # koşuyla doğar, terminal dallarda finalize olur, provide swap
        # semantiğiyle tekrarlanan !goal koşuları Ω'ya inverse yığmaz.
        # OFF iken hiçbir yüz kurulmaz (araç/URI/prompt bayt-özdeş).
        goal_ledger = initialize_goal_ledger(ctx, goal_text)

        # Askı kimliği (issue #106): koşu boyunca SABİT — registry
        # girdisinin anahtarı ve Σ damgası meta'sının goal_id'si.
        # (Σ satır id'si her kabulde değişir; kimlik olarak kullanılamaz.)
        goal_id = "goal-#{Process.pid}-#{SecureRandom.hex(4)}"

        ctx.out.puts "[Rubik::Goal] Starting autonomous goal loop (Budget: #{goal_steps} steps) with #{routed[:role]} model (#{routed[:model]})..."
        ctx.out.puts "[Rubik::Goal] Target: #{goal_text}\n"

        orchestrator = build_goal_orchestrator(ctx, goal_state: goal_state, routed: routed, steps: goal_steps)

        # Plan 53 D-8 yardımcısı: nötr çift + kayıtçı eşlemesi tek yerde.
        # Session restore kayıtçı OLAYLARINDAN hidrate eder — eşlenmiş
        # restore için conversation_history VE record_assistant_response
        # birlikte yazılmalı (başarısızlıkta da).
        record_goal_pair = build_goal_record_pair(ctx, goal_text)

        # Pruner apply seam: hedef döngüsü de aynı sınırda tohumlanır —
        # aşamalı budama planı varsa goal promptundan ÖNCE uygulanır.
        ctx.apply_staged_prune_plan!

        drive_goal_turn(ctx, orchestrator: orchestrator, goal_state: goal_state,
                             goal_ledger: goal_ledger, goal_text: goal_text, goal_id: goal_id,
                             record_pair: record_goal_pair,
                             start: ->(loop_inst) { loop_inst.run(goal_text, goal_mode: true, conversation_history: ctx.conversation_history) })
      end

      # ------------------------------------------------------------------
      # !goal sürücüsü (issue #106): koşu girişi + bütçe-soru döngüsü +
      # tek hata kanalı + terminal eşlemesi — start ve resume yollarının
      # ORTAK gövdesi. start callable'ı yolu seçer:
      #   başlangıç → loop.run (taze koşu)
      #   süreç-içi resume → loop.resume! (history prefix nesne-özdeş)
      #   çapraz-süreç resume → loop.resume_from (Σ penceresi)
      # Askı dalı (#106): SADECE transient ClientError SUSPENDED'a gider;
      # kalıcı hatalar (moderasyon/401/read-timeout) bugünkü fail_goal
      # çıktısını bayt-baytına korur.
      def drive_goal_turn(ctx, orchestrator:, goal_state:, goal_ledger:,
                          goal_text:, goal_id:, record_pair:, start:)
        ctx.active_loop = orchestrator
        begin
          res = start.call(orchestrator)
          res = handle_goal_budget_extensions(ctx, orchestrator: orchestrator, goal_state: goal_state, res: res)
        rescue Interrupt
          # ^C hedefi 'running' bırakmasın; eşlenmiş kayıt otursun. Interrupt
          # yeniden yükselir — kullanıcı mesajını execute_command basar.
          # Resume üstüne ^C = askıyı terk (terminal :stopped damgası).
          goal_state.stop!("Interrupted by user (^C)")
          finalize_goal_ledger(goal_ledger, goal_state, :stopped)
          forget_suspended_goal(ctx, goal_id)
          record_pair.call("[Goal attempt interrupted after #{goal_state.step_count} steps]")
          raise
        rescue Rubik::LLM::ClientError => e
          # Tek hata kanalı (#106 uzantısı): transient transport hatası
          # (RETRYABLE tükenmesi, tükenmiş 5xx, 429) goal'u SUSPENDED'a
          # götürür — loop/counters/Σ korunur, REPL yaşar. Kalıcı hata
          # (#105 çıktısı değişmeden) terminal fail. Yeniden yükseltmez —
          # spinner temizliği dispatch katmanına (execute_command) aittir.
          # next yerine return: rescue sonrası res'siz terminal
          # eşlemesine düşülmesin.
          if e.respond_to?(:transient?) && e.transient?
            suspend_goal_turn(ctx, orchestrator: orchestrator, goal_state: goal_state, goal_ledger: goal_ledger,
                                   goal_text: goal_text, goal_id: goal_id, record_pair: record_pair, reason: e.message,
                                   tokens: orchestrator.total_tokens)
          else
            fail_goal_turn(ctx, goal_state: goal_state, goal_ledger: goal_ledger, goal_id: goal_id,
                                record_pair: record_pair, reason: e.message)
          end
          return
        rescue StandardError => e
          fail_goal_turn(ctx, goal_state: goal_state, goal_ledger: goal_ledger, goal_id: goal_id,
                              record_pair: record_pair, reason: "#{e.class}: #{e.message}")
          return
        ensure
          ctx.active_loop = nil
        end

        handle_goal_completion(ctx, res: res, goal_state: goal_state, goal_ledger: goal_ledger,
                                    goal_id: goal_id, record_pair: record_pair)
      end

      def finalize_goal_ledger(goal_ledger, goal_state, status)
        return unless goal_ledger

        goal_ledger.finalize!(status)
        goal_state.ledger_id = goal_ledger.snapshot[:storage_id]
      end

      def fail_goal_turn(ctx, goal_state:, goal_ledger:, goal_id:, record_pair:,
                         reason:, tokens: nil, steps: nil)
        sanitized = Rubik::Platform.safe_utf8(reason.to_s)
        steps_used = steps || goal_state.step_count
        goal_state.fail!(sanitized, tokens: tokens)
        finalize_goal_ledger(goal_ledger, goal_state, :failed)
        forget_suspended_goal(ctx, goal_id)
        ctx.out.puts "\n❌ Goal could not be completed: #{sanitized}"
        record_pair.call("[Goal attempt ended after #{steps_used} steps: #{sanitized}]", tokens: tokens)
      end

      def suspend_goal_turn(ctx, orchestrator:, goal_state:, goal_ledger:,
                            goal_text:, goal_id:, record_pair:, reason:, tokens: nil)
        attempt = suspended_attempt(ctx, goal_id) + 1
        # Ledger kimliği askıdan ÖNCE okunur: suspend! → ledger.suspend!
        # sırası metanın bu turun token'larını içermesi için zorunlu,
        # ama o damga storage_id'yi değiştirdiği için sonradan atanan id
        # SUSPEND_EVENT'e geç kalırdı — ilk askıda kronik satırı slug
        # kimliğine düşer, ledger= bağlantısı kaybolurdu.
        # resume_cross_process ile aynı uçuş-içi atama önceliği.
        goal_state.ledger_id = goal_ledger.snapshot[:storage_id] if goal_ledger
        goal_state.suspend!(reason, tokens: tokens)
        goal_ledger&.suspend!(suspend_stamp_meta(goal_state, goal_id, reason, attempt))
        registry = goal_registry_for(ctx)
        registry.register(Rubik::Orchestrator::GoalRegistry::Entry.new(
                            goal_id: goal_id, goal_text: goal_text, loop: orchestrator,
                            goal_state: goal_state, ledger: goal_ledger, reason: reason.to_s,
                            suspended_at: Time.now, attempt: attempt
                          ))
        ctx.out.puts "\n⏸️ [Rubik::Goal] Suspended after #{goal_state.step_count} steps (transient provider error): #{reason}"
        ctx.out.puts "   Loop, counters and Σ ledger are preserved — resume with `!goal resume`."
        record_pair.call("[Goal suspended after #{goal_state.step_count} steps: #{reason}]", tokens: tokens)
      end

      def handle_goal_budget_extensions(ctx, orchestrator:, goal_state:, res:)
        # Bütçe tükenince sor (execute_free_text simetrisi; aynı knob,
        # aynı +20). continue_loop boyunca active_loop DOLU kalmalı:
        # notice yönlendirmesi aktif döngüye bakar (lifecycle.rb
        # route_subagent_notice) — soruya beklerken gelen subagent
        # olayları loop inbox'a girer ve devam adımında boşaltılır.
        auto_extensions = 0
        max_auto = ctx.config.fetch("agent.goal_auto_continue_limit", 0).to_i
        # Yapılandırılmış neden (loop.rb terminali): insan-okur string
        # yalnız gösterim içindir — otomasyon prozu parse etmesin.
        while !res[:ok] && res[:reason] == :budget_exhausted
          if auto_extensions < max_auto
            auto_extensions += 1
            ctx.out.puts "\n🤖 [Rubik::Goal] Adım bütçesi doldu (#{res[:error]}). " \
                         "Otonom devam hakkı (#{auto_extensions}/#{max_auto}) kullanılarak +20 adım ekleniyor..."
            goal_state.extend!(goal_state.max_steps + 20)
            res = orchestrator.continue_loop(20, auto: true)
            next
          end

          break unless ctx.config.fetch("agent.ask_continue_on_limit", true)

          ctx.out.puts "\n⚠️ [Rubik::Goal] #{res[:error]}"
          ans = ctx.ask_yes_no(" [Rubik::Goal] +20 adım ile devam edilsin mi?", default: "n")
          break unless ["y", "yes", "evet"].include?(ans)

          ctx.out.puts " [Rubik::Goal] Adım bütçesi +20 artırılıyor ve hedef sürdürülüyor..."
          goal_state.extend!(goal_state.max_steps + 20)
          res = orchestrator.continue_loop(20)
        end
        res
      end

      def handle_goal_completion(ctx, res:, goal_state:, goal_ledger:,
                                 goal_id:, record_pair:)
        if res[:ok]
          active = goal_active_subagent_count(ctx)
          if active.positive?
            # Defense behind the loop-level goal guard (GoalWait): a
            # success terminal escaping with live subagents means the
            # pipeline is mid-flight — an honest stop beats a false
            # "Goal Achieved" (field incident 2026-10-05).
            reason = "Goal loop concluded with #{active} active subagent(s) still running — not marked complete"
            goal_state.stop!(reason)
            finalize_goal_ledger(goal_ledger, goal_state, :stopped)
            ctx.out.puts "\n⚠️ [Rubik::Goal] #{reason}."
            record_pair.call("[Goal attempt ended after #{goal_state.step_count} steps: #{reason}]", tokens: res[:tokens])
          else
            goal_state.complete!(res[:output].to_s, tokens: res[:tokens])
            finalize_goal_ledger(goal_ledger, goal_state, :completed)
            forget_suspended_goal(ctx, goal_id)
            ctx.out.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
            ctx.out.puts res[:output]
            # Keep the bang syntax out of the LLM context (Plan 53 D-8): the
            # session recorder already stores the literal "!goal ..." for replay.
            record_pair.call(res[:output].to_s, streamed: res[:streamed] == true, tokens: res[:tokens])

            ctx.out.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk." if ctx.buffer_manager.dirty?
          end
        else
          # Başarısızlık eşlemesi yukarıdaki tek hata kanalından akar:
          # GoalState → ledger finalize → kayıtçı çifti, istisna yoluyla
          # aynı sırayla.
          fail_goal_turn(ctx, goal_state: goal_state, goal_ledger: goal_ledger, goal_id: goal_id,
                              record_pair: record_pair, reason: res[:error], tokens: res[:tokens], steps: res[:steps])
        end
      end

      # ------------------------------------------------------------------
      # !goal resume (issue #106). İki yol, dönüşüm sırasına göre:
      #   1) Oturum kaydında canlı girdi varsa süreç-içi resume — hayatta
      #      kalan Loop örneği canlandırılır (subagent konuşmaları gerçekten
      #      süreklidir; süpervizör sürecin yaşıyor).
      #   2) Yoksa çapraz-süreç Σ-only resume — storage'daki "suspended"
      #      satırından rehidrasyon. Alt ajan konuşmaları süreçle ölür;
      #      çıktı bunu tek cümleyle dürüstçe söyler.
      def resume_suspended_goal(ctx)
        registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
        entry = registry.latest if registry.is_a?(Rubik::Orchestrator::GoalRegistry)
        entry ? resume_in_process(ctx, entry) : resume_cross_process(ctx)
      end

      def resume_in_process(ctx, entry)
        ctx.recorder&.record_user_turn("!goal resume")
        # Kaynaklama (issue #454): canlı girdiden; resume! geçişi (SUSPENDED → RUNNING) kaynaklamanın parçası.
        goal_state = entry.goal_state
        goal_ledger = entry.ledger
        goal_state.resume!
        ctx.out.puts "[Rubik::Goal] Resuming '#{entry.goal_text}' (attempt #{entry.attempt + 1}, " \
                     "suspended: #{entry.reason})"
        # Dürüst süreklilik: alt ajan konuşmaları süreç-içi resume'da yaşar — çapraz-süreç
        # yoldaki tek cümlelik uyarı burada YOKTUR; ortak kuyruk resume_drive'da.
        resume_drive(ctx, orchestrator: entry.loop, goal_state: goal_state, ledger: goal_ledger,
                          goal_text: entry.goal_text, goal_id: entry.goal_id,
                          start: lambda { |loop_inst|
                            loop_inst.resume!(reason: entry.reason,
                                              suspended_at: entry.suspended_at,
                                              attempt: entry.attempt)
                          })
      end

      def resume_cross_process(ctx)
        ctx.recorder&.record_user_turn("!goal resume")
        store = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::STORAGE_STORE)
        unless store
          ctx.out.puts "ℹ️ [Rubik::Goal] No suspended goal in this session; storage unavailable — " \
                       "cross-process resume honestly refused."
          return
        end

        row = suspended_rows(store).last
        unless row
          ctx.out.puts "ℹ️ [Rubik::Goal] No suspended goal found (session registry empty, no 'suspended' Σ rows)."
          return
        end

        dmesg = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::DMESG)
        ledger = Rubik::Orchestrator::GoalLedger::Ledger.load(store: store, storage_id: row.id,
                                                              config: ctx.config, dmesg: dmesg,
                                                              event_bus: ctx.event_bus)
        unless ledger
          ctx.out.puts "⚠️ [Rubik::Goal] Suspended goal row #{row.id} could not be rehydrated — " \
                       "cross-process resume refused (corrupt or non-suspended stamp)."
          return
        end

        meta = ledger.suspend_meta || {}
        goal_text = ledger.snapshot[:objective].to_s
        goal_steps = meta["max_steps"].to_i.positive? ? meta["max_steps"].to_i : ctx.config.fetch("agent.goal_max_steps", 100).to_i
        goal_state = Rubik::Orchestrator::GoalState.new(event_bus: ctx.event_bus)
        goal_state.start!(goal_text, goal_steps)
        goal_state.restore_counters!(steps: meta["steps"], max_steps: goal_steps,
                                     extensions: meta["extensions"], tokens: meta["tokens"])
        goal_state.ledger_id = ledger.snapshot[:storage_id]

        routed = ctx.router.route(task_type: :goal, prompt: goal_text)
        ctx.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]
        # Kaynaklama (issue #454): döngü build_goal_orchestrator ile yeniden
        # kurulur — canlı Loop sürecle öldü (bilinçli asimetri; süreç-içi
        # yolda entry.loop kullanılır).
        orchestrator = build_goal_orchestrator(ctx, goal_state: goal_state, routed: routed, steps: goal_steps)

        ctx.out.puts "[Rubik::Goal] Cross-process resume of '#{goal_text}' (attempt #{meta['attempt'].to_i})..."
        # Dürüst süreklilik cümlesi (tasarım sözleşmesi): alt ajan
        # konuşmaları süreçle öldü; disk etkileri ve session kaydı yaşar.
        ctx.out.puts "   Subagent conversations did not survive the process restart — their disk " \
                     "effects and the session record have."
        resume_drive(ctx, orchestrator: orchestrator, goal_state: goal_state, ledger: ledger,
                          goal_text: goal_text,
                          goal_id: meta["goal_id"].to_s.empty? ? row.id : meta["goal_id"],
                          start: lambda { |loop_inst|
                            loop_inst.resume_from(goal_text: goal_text, ledger: ledger,
                                                  reason: meta["reason"].to_s,
                                                  suspended_at: parse_suspended_at(meta["suspended_at"]),
                                                  attempt: meta["attempt"].to_i,
                                                  counters: { steps: meta["steps"], max_steps: goal_steps,
                                                              tokens: meta["tokens"] })
                          })
      end

      # Resume ortak kuyruğu (issue #454): suspend_stamp_meta'nın resume
      # tarafındaki aynası — coeffect sağlama disiplini (GOAL_STATE +
      # sağlanan GOAL_LEDGER), Σ unsuspend!, nötr kayıtçı çifti, pruner
      # apply sınırı, tek drive_goal_turn stanza'sı: "resume hangi
      # coeffect'leri sağlar?" sorusunun TEK cevabı. Bilinçli asimetri
      # arayan tarafta kalır (erken birleştirme yok): kaynaklama, dürüst
      # süreklilik cümleleri ve döngü — süreç-içi yolda canlı entry.loop,
      # çapraz-süreç yolda build_goal_orchestrator; start callable'ı yolu
      # seçer (loop.resume! vs loop.resume_from).
      def resume_drive(ctx, orchestrator:, goal_state:, ledger:, goal_text:, goal_id:, start:)
        ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_STATE, goal_state)
        ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_LEDGER, ledger) if ledger
        ledger&.unsuspend!
        record_pair = build_goal_record_pair(ctx, goal_text)
        # Pruner apply seam: hedef döngüsü de aynı sınırda tohumlanır —
        # aşamalı budama planı varsa goal promptundan ÖNCE uygulanır.
        ctx.apply_staged_prune_plan!
        drive_goal_turn(ctx, orchestrator: orchestrator, goal_state: goal_state,
                             goal_ledger: ledger, goal_text: goal_text, goal_id: goal_id,
                             record_pair: record_pair, start: start)
      end
      private_class_method :resume_drive

      # !goal list (issue #106 Faz 2a): store'daki status == "suspended"
      # Σ satırları — özetler zaten status taşıyor (Store::Summary).
      def list_suspended_goals(ctx)
        ctx.recorder&.record_user_turn("!goal list")
        store = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::STORAGE_STORE)
        unless store
          ctx.out.puts "ℹ️ [Rubik::Goal] Storage unavailable — the suspended-goal list needs goal.ledger storage."
          return
        end

        rows = suspended_rows(store)
        if rows.empty?
          ctx.out.puts "ℹ️ [Rubik::Goal] No suspended goals."
          return
        end

        ctx.out.puts "=== Suspended goals ==="
        rows.each do |s|
          ctx.out.puts "  #{s.id}  #{s.updated_at}  #{s.title}"
        end
        ctx.out.puts "Resume the latest with: !goal resume"
      end

      # Askı satırları: en eski → en yeni sıralı (updated_at; kuiratör
      # list yüzeyiyle aynı alan). Sort anahtarı eşitse row sırası.
      def suspended_rows(store)
        store.list(type: "goal").select { |s| s.status == "suspended" }.sort_by(&:updated_at)
      end

      # Σ damgası meta'sı (issue #106): {goal_id, steps, max_steps,
      # extensions, tokens, reason, suspended_at, attempt}. Sembol
      # anahtarlar Ledger#suspend! içinde dizgeleştirilir.
      def suspend_stamp_meta(goal_state, goal_id, reason, attempt)
        { goal_id: goal_id, steps: goal_state.step_count, max_steps: goal_state.max_steps,
          extensions: goal_state.extensions, tokens: goal_state.tokens.dup,
          reason: reason.to_s.slice(0, 300), suspended_at: Time.now.utc.iso8601, attempt: attempt }
      end

      def suspended_attempt(ctx, goal_id)
        registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
        registry&.fetch(goal_id)&.attempt.to_i
      end

      # Oturum kaydı coeffect'i: ilk askıda provide edilir (provide-swap
      # semantiği — Context#provide anahtar başına TEK delete-inverse
      # tutar; tekrarlanan suspend/resume Ω'yı büyütmez).
      def goal_registry_for(ctx)
        registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
        return registry if registry.is_a?(Rubik::Orchestrator::GoalRegistry)

        registry = Rubik::Orchestrator::GoalRegistry.new
        ctx.runtime_manager&.provide(Rubik::Coeffects::GOAL_REGISTRY, registry)
        registry
      end

      # Terminal yollarda girdi temizliği: kayıt SADECE sağlanmışsa —
      # askı hiç yaşanmamış bir koşunun terminali boş registry provide
      # ETMEMELİ (Ω disiplini).
      def forget_suspended_goal(ctx, goal_id)
        registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
        registry.delete(goal_id) if registry.is_a?(Rubik::Orchestrator::GoalRegistry)
      end

      # Adım olayı lambda'sı (start + cross-process resume ortak): sayaç
      # akışı, kayıtçı tool çiftleri, render — start yolundaki satır içi
      # gövdenin birebir taşınması.
      def build_goal_on_step(ctx, goal_state)
        lambda { |step_info|
          # Adım sayacı rubik://goal/state'e aksın: olaylar bir adım
          # içinde tekrarlanabilir, GoalState monotoniktir (zararsız).
          goal_state.update_steps(step_info[:step], step_info[:max_steps]) if step_info[:step].is_a?(Integer)
          # Session teşhis edilebilirliği (field incident 2026-10-12):
          # saatler süren !goal koşuları session dosyasına tek satır
          # düşürüyordu — free-text turn simetrisinde tool adımları
          # kayıtçıya akar; render ve LLM geçmişi değişmez.
          case step_info[:type]&.to_sym
          when :tool_call
            ctx.recorder&.record_tool_call(step_info[:tool], step_info[:args], call_id: step_info[:call_id])
          when :tool_result
            ctx.recorder&.record_tool_result(step_info[:tool], step_info[:output], status: step_info[:status] || :ok, call_id: step_info[:call_id])
          end
          ctx.render_step_event(step_info)
        }
      end

      # Plan 53 D-8 yardımcısı: nötr çift + kayıtçı eşlemesi tek yerde.
      # Session restore kayıtçı OLAYLARINDAN hidrate eder — eşlenmiş
      # restore için conversation_history VE record_assistant_response
      # birlikte yazılmalı (başarısızlıkta da).
      def build_goal_record_pair(ctx, goal_text)
        lambda do |assistant_content, streamed: nil, tokens: nil|
          ctx.conversation_history << { role: "user", content: "Goal: #{goal_text}" }
          ctx.conversation_history << { role: "assistant", content: assistant_content }
          ctx.recorder&.record_assistant_response(assistant_content, tokens: tokens, streamed: streamed)
          ctx.trim_conversation_window!
        end
      end

      # The goal-shaped orchestrator-loop stanza's single home (issue #404).
      # execute_goal (fresh run) and resume_cross_process (Σ-window
      # rehydration) build the SAME shape — orchestrator_loop +
      # warn_at_ratio + the goal on_step lambda — so the construction is
      # folded here once. The plan command (render-only on_step, no
      # warn_at_ratio) and input_execution (streaming on_step) keep their
      # materially different stanzas inline at their own sites.
      def build_goal_orchestrator(ctx, goal_state:, routed:, steps:)
        warn_ratio = ctx.config.fetch("agent.warn_at_ratio", 0.75).to_f
        ctx.orchestrator_loop(
          provider: routed[:provider],
          model: routed[:model],
          max_steps: steps,
          warn_at_ratio: warn_ratio,
          context_limit: routed[:context_limit],
          max_output_tokens: routed[:max_output_tokens],
          on_step: build_goal_on_step(ctx, goal_state)
        )
      end
      private_class_method :build_goal_orchestrator

      # Damga meta'sındaki suspended_at (iso8601) → Time; bozuk değer
      # nil — Loop#append_resume_marker! "unknown" downtime basar.
      def parse_suspended_at(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Defense-in-depth behind the loop-level goal guard: if a success
      # terminal escapes GoalWait with live subagent units, the goal must
      # stop honestly instead of celebrating a false completion. Fails
      # CONSERVATIVE: coeffect absence is nil-safe (Coeffects.get never
      # raises for a missing subsystem), so a raise here is real breakage
      # — reporting zero would launder it into exactly the false
      # "Goal Achieved" this backstop exists to refuse.
      def goal_active_subagent_count(ctx)
        supervisor = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
        supervisor&.active_count.to_i
      rescue StandardError => e
        Rubik::Log.warn(:orchestrator, "goal completion defense could not inspect subagents " \
                                       "(#{e.class}: #{e.message}); refusing completion")
        1
      end
    end
  end
end
