# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "base"
require_relative "../../runtime"
require_relative "../../sandbox"
require_relative "../../orchestrator/auto_apply"

module Rubik
  module REPL
    module Commands
      module AgentExecution
        extend Base

        # Whole-command synopses: shared by the spine registration (usage:)
        # and the empty-args branches that print them, so the two cannot drift.
        USAGE_PLAN = "Kullanım: !plan <görev açıklaması>"
        USAGE_GOAL = "Kullanım: !goal [--steps N|-s N] <hedef açıklaması>  |  !goal resume  |  !goal list"

        def self.register(shell)
          register_plan_command(shell)
          register_goal_command(shell)
          register_test_command(shell)
          register_lint_command(shell)
          register_format_command(shell)
          register_sh_command(shell)
          register_sandbox_command(shell)
        end

        private_class_method def self.register_plan_command(shell)
          shell.register_command("plan", description: "Formulate step-by-step plan for a task and ask for confirmation",
                                         usage: USAGE_PLAN) do |args, ctx|
            task = args.join(" ").strip
            if task.empty?
              ctx.out.puts USAGE_PLAN
              next
            end

            plan_steps = ctx.config.fetch("agent.plan_max_steps", 15).to_i
            routed = ctx.router.route(task_type: :plan, prompt: task)
            ctx.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]
            orchestrator = ctx.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: plan_steps,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: ->(step_info) { ctx.render_step_event(step_info) }
            )

            ctx.out.puts "[Rubik::Plan] Generating plan using #{routed[:role]} model (#{routed[:model]})..."
            res = orchestrator.run(task, plan_only: true)

            if res[:ok]
              ctx.out.puts "\n=== Proposed Plan ==="
              ctx.out.puts res[:output]
              ctx.out.puts "=====================\n"
              ans = ctx.ask_yes_no("[Rubik::Plan] Plan uygulansın mı?", default: "y")
              if ["y", "yes", "evet"].include?(ans)
                ctx.out.puts "[Rubik::Act] Executing approved plan..."
                ctx.execute_free_text("Execute the following approved plan step by step:\n#{res[:output]}")
              else
                ctx.out.puts "[Rubik] Plan iptal edildi."
              end
            else
              ctx.out.puts "Plan üretilemedi: #{res[:error]}"
            end
          end
        end

        private_class_method def self.register_goal_command(shell)
          shell.register_command("goal", description: "Run long-running autonomous goal loop (the maestro supervises a subagent pipeline) until all tests pass",
                                         usage: USAGE_GOAL) do |args, ctx|
            # Askı alt-komutları (issue #106): !goal resume | !goal list.
            # Tek-argüman şartı: "Resume the deployment" gibi hedef metinleri
            # alt-komut olarak yakalanamaz.
            sub = args.first.to_s.downcase
            next resume_suspended_goal(ctx) if args.length == 1 && sub == "resume"
            next list_suspended_goals(ctx) if args.length == 1 && sub == "list"

            parsed = parse_goal_args(args)
            if !parsed[:valid]
              ctx.out.puts USAGE_GOAL
              ctx.out.puts "⚠️ [Rubik::Goal] --steps pozitif bir tam sayı bekliyor (örn. !goal --steps 200 <hedef>)"
              next
            elsif parsed[:goal_text].empty?
              ctx.out.puts USAGE_GOAL
              next
            end

            execute_goal(ctx, parsed[:goal_text], parsed[:custom_steps])
          end
        end

        private_class_method def self.parse_goal_args(args)
          custom_steps = nil
          bad_steps = false
          filtered_args = []
          i = 0
          while i < args.length
            arg = args[i]
            if (m = arg.match(/\A--steps=(\d+)\z/))
              custom_steps = m[1].to_i
            elsif arg.start_with?("--steps=")
              # --steps=X ama X sayı değil: flag metne sızmasın.
              bad_steps = true
            elsif ["--steps", "-s"].include?(arg)
              if i + 1 < args.length && args[i + 1] =~ /\A\d+\z/
                custom_steps = args[i + 1].to_i
                i += 1
              else
                # Değersiz/sayı-olmayan değer: kullanım hatası (sessiz
                # yanlış koşu yerine).
                bad_steps = true
              end
            else
              filtered_args << arg
            end
            i += 1
          end

          goal_text = filtered_args.join(" ").strip
          valid = !bad_steps && (custom_steps.nil? || custom_steps >= 1)
          { custom_steps: custom_steps, goal_text: goal_text, valid: valid }
        end

        private_class_method def self.initialize_goal_ledger(ctx, goal_text)
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

        private_class_method def self.execute_goal(ctx, goal_text, custom_steps)
          ctx.recorder&.record_user_turn("!goal #{goal_text}")
          goal_steps = custom_steps || ctx.config.fetch("agent.goal_max_steps", 100).to_i
          warn_ratio = ctx.config.fetch("agent.warn_at_ratio", 0.75).to_f
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

          orchestrator = ctx.orchestrator_loop(
            provider: routed[:provider],
            model: routed[:model],
            max_steps: goal_steps,
            warn_at_ratio: warn_ratio,
            context_limit: routed[:context_limit],
            max_output_tokens: routed[:max_output_tokens],
            on_step: build_goal_on_step(ctx, goal_state)
          )

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
        private_class_method def self.drive_goal_turn(ctx, orchestrator:, goal_state:, goal_ledger:,
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
                                     goal_text: goal_text, goal_id: goal_id, record_pair: record_pair, reason: e.message)
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

        private_class_method def self.finalize_goal_ledger(goal_ledger, goal_state, status)
          return unless goal_ledger

          goal_ledger.finalize!(status)
          goal_state.ledger_id = goal_ledger.snapshot[:storage_id]
        end

        private_class_method def self.fail_goal_turn(ctx, goal_state:, goal_ledger:, goal_id:, record_pair:,
                                                        reason:, tokens: nil, steps: nil)
          sanitized = Rubik::Platform.safe_utf8(reason.to_s)
          steps_used = steps || goal_state.step_count
          goal_state.fail!(sanitized, tokens: tokens)
          finalize_goal_ledger(goal_ledger, goal_state, :failed)
          forget_suspended_goal(ctx, goal_id)
          ctx.out.puts "\n❌ Goal could not be completed: #{sanitized}"
          record_pair.call("[Goal attempt ended after #{steps_used} steps: #{sanitized}]", tokens: tokens)
        end

        private_class_method def self.suspend_goal_turn(ctx, orchestrator:, goal_state:, goal_ledger:,
                                                         goal_text:, goal_id:, record_pair:, reason:, tokens: nil)
          attempt = suspended_attempt(ctx, goal_id) + 1
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

        private_class_method def self.handle_goal_budget_extensions(ctx, orchestrator:, goal_state:, res:)
          # Bütçe tükenince sor (execute_free_text simetrisi; aynı knob,
          # aynı +20). continue_loop boyunca active_loop DOLU kalmalı:
          # notice yönlendirmesi aktif döngüye bakar (lifecycle.rb
          # route_subagent_notice) — soruya beklerken gelen subagent
          # olayları loop inbox'a girer ve devam adımında boşaltılır.
          auto_extensions = 0
          max_auto = ctx.config.fetch("agent.goal_auto_continue_limit", 0).to_i
          while !res[:ok] && res[:error]&.include?("Max steps budget exceeded")
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

        private_class_method def self.handle_goal_completion(ctx, res:, goal_state:, goal_ledger:,
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
        private_class_method def self.resume_suspended_goal(ctx)
          registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
          entry = registry.latest if registry.is_a?(Rubik::Orchestrator::GoalRegistry)
          entry ? resume_in_process(ctx, entry) : resume_cross_process(ctx)
        end

        private_class_method def self.resume_in_process(ctx, entry)
          ctx.recorder&.record_user_turn("!goal resume")
          goal_state = entry.goal_state
          goal_ledger = entry.ledger
          ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_STATE, goal_state)
          ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_LEDGER, goal_ledger) if goal_ledger
          goal_ledger&.unsuspend!
          goal_state.resume!
          ctx.out.puts "[Rubik::Goal] Resuming '#{entry.goal_text}' (attempt #{entry.attempt + 1}, " \
                       "suspended: #{entry.reason})"
          # Dürüst süreklilik cümlesi: alt ajan konuşmaları süreç-içi
          # resume'da yaşar — çapraz-süreç yoldaki tek cümlelik uyarı burada
          # YOKTUR (gerçek süreklilik).
          record_pair = build_goal_record_pair(ctx, entry.goal_text)
          ctx.apply_staged_prune_plan!
          drive_goal_turn(ctx, orchestrator: entry.loop, goal_state: goal_state,
                               goal_ledger: goal_ledger, goal_text: entry.goal_text,
                               goal_id: entry.goal_id, record_pair: record_pair,
                               start: lambda { |loop_inst|
                                 loop_inst.resume!(reason: entry.reason,
                                                   suspended_at: entry.suspended_at,
                                                   attempt: entry.attempt)
                               })
        end

        private_class_method def self.resume_cross_process(ctx)
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
          warn_ratio = ctx.config.fetch("agent.warn_at_ratio", 0.75).to_f
          goal_state = Rubik::Orchestrator::GoalState.new(event_bus: ctx.event_bus)
          goal_state.start!(goal_text, goal_steps)
          goal_state.restore_counters!(steps: meta["steps"], max_steps: goal_steps,
                                       extensions: meta["extensions"], tokens: meta["tokens"])
          goal_state.ledger_id = ledger.snapshot[:storage_id]
          ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_STATE, goal_state)
          ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_LEDGER, ledger)

          routed = ctx.router.route(task_type: :goal, prompt: goal_text)
          ctx.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]
          orchestrator = ctx.orchestrator_loop(
            provider: routed[:provider],
            model: routed[:model],
            max_steps: goal_steps,
            warn_at_ratio: warn_ratio,
            context_limit: routed[:context_limit],
            max_output_tokens: routed[:max_output_tokens],
            on_step: build_goal_on_step(ctx, goal_state)
          )

          ctx.out.puts "[Rubik::Goal] Cross-process resume of '#{goal_text}' (attempt #{meta['attempt'].to_i})..."
          # Dürüst süreklilik cümlesi (tasarım sözleşmesi): alt ajan
          # konuşmaları süreçle öldü; disk etkileri ve session kaydı yaşar.
          ctx.out.puts "   Subagent conversations did not survive the process restart — their disk " \
                       "effects and the session record have."
          ledger.unsuspend!
          record_pair = build_goal_record_pair(ctx, goal_text)
          ctx.apply_staged_prune_plan!
          drive_goal_turn(ctx, orchestrator: orchestrator, goal_state: goal_state,
                               goal_ledger: ledger, goal_text: goal_text,
                               goal_id: meta["goal_id"].to_s.empty? ? row.id : meta["goal_id"],
                               record_pair: record_pair,
                               start: lambda { |loop_inst|
                                 loop_inst.resume_from(goal_text: goal_text, ledger: ledger,
                                                       reason: meta["reason"].to_s,
                                                       suspended_at: parse_suspended_at(meta["suspended_at"]),
                                                       attempt: meta["attempt"].to_i,
                                                       counters: { steps: meta["steps"], max_steps: goal_steps,
                                                                   tokens: meta["tokens"] })
                               })
        end

        # !goal list (issue #106 Faz 2a): store'daki status == "suspended"
        # Σ satırları — özetler zaten status taşıyor (Store::Summary).
        private_class_method def self.list_suspended_goals(ctx)
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
        private_class_method def self.suspended_rows(store)
          store.list(type: "goal").select { |s| s.status == "suspended" }.sort_by(&:updated_at)
        end

        # Σ damgası meta'sı (issue #106): {goal_id, steps, max_steps,
        # extensions, tokens, reason, suspended_at, attempt}. Sembol
        # anahtarlar Ledger#suspend! içinde dizgeleştirilir.
        private_class_method def self.suspend_stamp_meta(goal_state, goal_id, reason, attempt)
          { goal_id: goal_id, steps: goal_state.step_count, max_steps: goal_state.max_steps,
            extensions: goal_state.extensions, tokens: goal_state.tokens.dup,
            reason: reason.to_s.slice(0, 300), suspended_at: Time.now.utc.iso8601, attempt: attempt }
        end

        private_class_method def self.suspended_attempt(ctx, goal_id)
          registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
          registry&.fetch(goal_id)&.attempt.to_i
        end

        # Oturum kaydı coeffect'i: ilk askıda provide edilir (provide-swap
        # semantiği — Context#provide anahtar başına TEK delete-inverse
        # tutar; tekrarlanan suspend/resume Ω'yı büyütmez).
        private_class_method def self.goal_registry_for(ctx)
          registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
          return registry if registry.is_a?(Rubik::Orchestrator::GoalRegistry)

          registry = Rubik::Orchestrator::GoalRegistry.new
          ctx.runtime_manager&.provide(Rubik::Coeffects::GOAL_REGISTRY, registry)
          registry
        end

        # Terminal yollarda girdi temizliği: kayıt SADECE sağlanmışsa —
        # askı hiç yaşanmamış bir koşunun terminali boş registry provide
        # ETMEMELİ (Ω disiplini).
        private_class_method def self.forget_suspended_goal(ctx, goal_id)
          registry = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::GOAL_REGISTRY)
          registry.delete(goal_id) if registry.is_a?(Rubik::Orchestrator::GoalRegistry)
        end

        # Adım olayı lambda'sı (start + cross-process resume ortak): sayaç
        # akışı, kayıtçı tool çiftleri, render — start yolundaki satır içi
        # gövdenin birebir taşınması.
        private_class_method def self.build_goal_on_step(ctx, goal_state)
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
        private_class_method def self.build_goal_record_pair(ctx, goal_text)
          lambda do |assistant_content, streamed: nil, tokens: nil|
            ctx.conversation_history << { role: "user", content: "Goal: #{goal_text}" }
            ctx.conversation_history << { role: "assistant", content: assistant_content }
            ctx.recorder&.record_assistant_response(assistant_content, tokens: tokens, streamed: streamed)
            ctx.trim_conversation_window!
          end
        end

        # Damga meta'sındaki suspended_at (iso8601) → Time; bozuk değer
        # nil — Loop#append_resume_marker! "unknown" downtime basar.
        private_class_method def self.parse_suspended_at(value)
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
        private_class_method def self.goal_active_subagent_count(ctx)
          supervisor = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
          supervisor&.active_count.to_i
        rescue StandardError => e
          Rubik::Log.warn(:orchestrator, "goal completion defense could not inspect subagents " \
                                         "(#{e.class}: #{e.message}); refusing completion")
          1
        end

        private_class_method def self.register_test_command(shell)
          shell.register_command("test", description: "Run test suite via active language adapter") do |args, ctx|
            if ctx.buffer_manager&.dirty?
              if Rubik::Orchestrator::AutoApply.apply?(ctx.config, trigger: :pre_execution)
                applied = Rubik::Orchestrator::AutoApply.apply_and_sync(ctx.buffer_manager, ctx)
                ctx.out.puts Rubik::Orchestrator::AutoApply.applied_line(applied.size, "test run")
              else
                ctx.out.puts Rubik::Orchestrator::AutoApply.unapplied_warning("Tests")
              end
            end
            lang = args.first || Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
            adapter = ctx.adapter_registry.get(lang) || ctx.adapter_registry.get("ruby")
            res = adapter.run_tests(Dir.pwd)
            ctx.out.puts res[:output]
            if !res[:ok] && res[:diagnostic]
              ctx.out.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
              ctx.out.puts "Tip: Use `repair_runtime_service` (or `fix_service`) to adapt test runners dynamically."
            end
          end
        end

        private_class_method def self.register_lint_command(shell)
          shell.register_command("lint", description: "Run linter/syntax check", audience: :both) do |args, ctx|
            target = args.first || "lib/rubik.rb"
            lang = Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
            adapter = ctx.adapter_registry.get(lang) || ctx.adapter_registry.get("ruby")
            res = adapter.check_syntax(target)
            ctx.out.puts res[:output]
            ctx.out.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}" if !res[:ok] && res[:diagnostic]
          end
        end

        private_class_method def self.register_format_command(shell)
          shell.register_command("format", description: "Format target file", audience: :both) do |args, ctx|
            target = args.first
            if target
              lang = Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
              adapter = ctx.adapter_registry.get(lang) || ctx.adapter_registry.get("ruby")
              res = adapter.format_code(target)
              ctx.out.puts res[:output]
              ctx.out.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}" if !res[:ok] && res[:diagnostic]
            end
          end
        end

        private_class_method def self.register_sh_command(shell)
          shell.register_command("sh", description: "Execute shell command via sandbox runner") do |args, ctx|
            if ctx.buffer_manager&.dirty?
              if Rubik::Orchestrator::AutoApply.apply?(ctx.config, trigger: :pre_execution)
                applied = Rubik::Orchestrator::AutoApply.apply_and_sync(ctx.buffer_manager, ctx)
                ctx.out.puts Rubik::Orchestrator::AutoApply.applied_line(applied.size, "command execution")
              else
                ctx.out.puts Rubik::Orchestrator::AutoApply.unapplied_warning("Commands")
              end
            end

            cmd = args.join(" ")
            ctx.guard.verify_command_safety!(cmd)
            runner = ctx.sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: ctx.config, guard: ctx.guard)
            res = runner.run(cmd)
            ctx.out.puts res[:output]
          end
        end

        private_class_method def self.register_sandbox_command(shell)
          shell.register_command("sandbox", description: "Inspect or configure sandbox isolation (bwrap/docker/podman)") do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            subcmd = clean_args.first.to_s.downcase

            registered_map = Rubik::Sandbox::Driver.registered_drivers
            registered_keys = registered_map.keys.uniq

            if clean_args.empty? || subcmd == "status"
              enabled = ctx.config.fetch("sandbox.enabled", false)
              state_str = enabled ? "Açık (enabled)" : "Kapalı (disabled - direct safe execution)"
              driver_name = ctx.sandbox_runner&.driver&.name || ctx.config.fetch("sandbox.driver", "bwrap")
              net_str = ctx.config.fetch("sandbox.allow_network", false) ? "allowed" : "blocked"

              ctx.out.puts "=== Sandbox Durumu ==="
              ctx.out.puts "Durum:       #{state_str}"
              ctx.out.puts "Aktif Motor: #{driver_name}"
              ctx.out.puts "Ağ:          #{net_str}"
              ctx.out.puts "Kayıtlı:     #{registered_keys.join(', ')}"
            elsif subcmd == "on"
              res = ctx.config.set("sandbox.enabled", true, persist: scope)
              driver_res = ctx.config.set("sandbox.driver", "bwrap", persist: scope) if Rubik::Platform.linux?
              next if Base.report_persist_failure(ctx, res, scope)
              next if Base.report_persist_failure(ctx, driver_res, scope)

              ctx.out.puts "[Sandbox] Enabled (#{ctx.sandbox_runner&.driver&.name || 'default'})."
            elsif subcmd == "off"
              res = ctx.config.set("sandbox.enabled", false, persist: scope)
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "[Sandbox] Disabled (direct safe execution active)."
            elsif registered_map.key?(subcmd)
              ctx.out.puts "⚠️ [Sandbox] 'bwrap' yalnızca Linux üzerinde desteklenir." if ["bwrap", "bubblewrap"].include?(subcmd) && !Rubik::Platform.linux?
              res = ctx.config.set("sandbox.enabled", true, persist: scope)
              driver_res = ctx.config.set("sandbox.driver", subcmd, persist: scope)
              next if Base.report_persist_failure(ctx, res, scope)
              next if Base.report_persist_failure(ctx, driver_res, scope)

              ctx.out.puts "[Sandbox] Driver set to '#{subcmd}' (enabled)."
            else
              ctx.out.puts "[Sandbox] Bilinmeyen alt komut veya sürücü: '#{subcmd}'. Kayıtlı sürücüler: #{registered_keys.join(', ')}"
            end
          end
        end
      end
    end
  end
end
