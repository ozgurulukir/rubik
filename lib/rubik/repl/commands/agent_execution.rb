# frozen_string_literal: true

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
        USAGE_GOAL = "Kullanım: !goal <hedef açıklaması>"

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
            goal_text = args.join(" ").strip
            if goal_text.empty?
              ctx.out.puts USAGE_GOAL
              next
            end

            ctx.recorder&.record_user_turn("!goal #{goal_text}")
            goal_steps = ctx.config.fetch("agent.goal_max_steps", 100).to_i
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
            goal_ledger = nil
            if Rubik::Orchestrator::GoalLedger::Ledger.enabled?(ctx.config)
              store = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::STORAGE_STORE)
              dmesg = Rubik::Coeffects.get(ctx.runtime_manager&.context, Rubik::Coeffects::DMESG)
              goal_ledger = Rubik::Orchestrator::GoalLedger::Ledger.create!(
                goal_text: goal_text, config: ctx.config, store: store, dmesg: dmesg,
                event_bus: ctx.event_bus
              )
              ctx.runtime_manager.provide(Rubik::Coeffects::GOAL_LEDGER, goal_ledger)
            end
            finalize_ledger = lambda do |status|
              next unless goal_ledger

              goal_ledger.finalize!(status)
              goal_state.ledger_id = goal_ledger.snapshot[:storage_id]
            end

            ctx.out.puts "[Rubik::Goal] Starting autonomous goal loop (Budget: #{goal_steps} steps) with #{routed[:role]} model (#{routed[:model]})..."
            ctx.out.puts "[Rubik::Goal] Target: #{goal_text}\n"

            orchestrator = ctx.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: goal_steps,
              warn_at_ratio: warn_ratio,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: lambda { |step_info|
                # Adım sayacı rubik://goal/state'e aksın: olaylar bir adım
                # içinde tekrarlanabilir, GoalState monotoniktir (zararsız).
                goal_state.update_steps(step_info[:step], step_info[:max_steps]) if step_info[:step].is_a?(Integer)
                ctx.render_step_event(step_info)
              }
            )

            # Plan 53 D-8 yardımcısı: nötr çift + kayıtçı eşlemesi tek yerde.
            # Session restore kayıtçı OLAYLARINDAN hidrate eder — eşlenmiş
            # restore için conversation_history VE record_assistant_response
            # birlikte yazılmalı (başarısızlıkta da).
            record_goal_pair = lambda do |assistant_content, streamed: nil, tokens: nil|
              ctx.conversation_history << { role: "user", content: "Goal: #{goal_text}" }
              ctx.conversation_history << { role: "assistant", content: assistant_content }
              ctx.recorder&.record_assistant_response(assistant_content, tokens: tokens, streamed: streamed)
              ctx.trim_conversation_window!
            end

            # Pruner apply seam: hedef döngüsü de aynı sınırda tohumlanır —
            # aşamalı budama planı varsa goal promptundan ÖNCE uygulanır.
            ctx.apply_staged_prune_plan!

            # Tek hata kanalı (field incident 2026-10-12): eskiden yalnızca
            # normal :error dönüşü başarısızlık eşlemesini yapıyordu; loop'tan
            # kaçan bir ClientError (sağlayıcı read timeout) goal'u kayıtsız
            # 'running' bırakıyor, ledger terminal görmiyor ve session
            # dosyası sessiz kalıyordu. Rescue dalları da aynı kapanış
            # sırasını buradan çalıştırır. Kayıtçı '!goal ...' user_turn'unu
            # komut girişinde çoktan yazdı — assistant_response olmadan
            # session restore EŞLEŞMEMİŞ bir 'Goal: ...' turu hidrate ederdi.
            # Adım sayısı: loop'un truncation hatası :steps'siz döner —
            # GoalState monotonik sayacı otoriter yedek.
            fail_goal = lambda do |reason, tokens: nil, steps: nil|
              sanitized = Rubik::Platform.safe_utf8(reason.to_s)
              steps_used = steps || goal_state.step_count
              goal_state.fail!(sanitized, tokens: tokens)
              finalize_ledger.call(:failed)
              ctx.out.puts "\n❌ Goal could not be completed: #{sanitized}"
              record_goal_pair.call("[Goal attempt ended after #{steps_used} steps: #{sanitized}]", tokens: tokens)
            end

            ctx.active_loop = orchestrator
            begin
              res = orchestrator.run(goal_text, goal_mode: true, conversation_history: ctx.conversation_history)

              # Bütçe tükenince sor (execute_free_text simetrisi; aynı knob,
              # aynı +20). continue_loop boyunca active_loop DOLU kalmalı:
              # notice yönlendirmesi aktif döngüye bakar (lifecycle.rb
              # route_subagent_notice) — soruya beklerken gelen subagent
              # olayları loop inbox'a girer ve devam adımında boşaltılır.
              while !res[:ok] && res[:error]&.include?("Max steps budget exceeded") && ctx.config.fetch("agent.ask_continue_on_limit", true)
                ctx.out.puts "\n⚠️ [Rubik::Goal] #{res[:error]}"
                ans = ctx.ask_yes_no(" [Rubik::Goal] +20 adım ile devam edilsin mi?", default: "n")
                break unless ["y", "yes", "evet"].include?(ans)

                ctx.out.puts " [Rubik::Goal] Adım bütçesi +20 artırılıyor ve hedef sürdürülüyor..."
                goal_state.extend!(goal_state.max_steps + 20)
                res = orchestrator.continue_loop(20)
              end
            rescue Interrupt
              # ^C hedefi 'running' bırakmasın; eşlenmiş kayıt otursun. Interrupt
              # yeniden yükselir — kullanıcı mesajını execute_command basar.
              goal_state.stop!("Interrupted by user (^C)")
              finalize_ledger.call(:stopped)
              record_goal_pair.call("[Goal attempt interrupted after #{goal_state.step_count} steps]")
              raise
            rescue Rubik::LLM::ClientError => e
              # execute_free_text simetrisi: sağlayıcı hatası (read timeout,
              # HTTP 4xx) kaçarsa da goal terminal görür. Yeniden yükseltmez —
              # spinner temizliği dispatch katmanına (execute_command) aittir.
              # next: rescue sonrası akış res'siz `if res[:ok]`'a düşmesin.
              fail_goal.call(e.message)
              next
            rescue StandardError => e
              fail_goal.call("#{e.class}: #{e.message}")
              next
            ensure
              ctx.active_loop = nil
            end
            if res[:ok]
              active = goal_active_subagent_count(ctx)
              if active.positive?
                # Defense behind the loop-level goal guard (GoalWait): a
                # success terminal escaping with live subagents means the
                # pipeline is mid-flight — an honest stop beats a false
                # "Goal Achieved" (field incident 2026-10-05).
                reason = "Goal loop concluded with #{active} active subagent(s) still running — not marked complete"
                goal_state.stop!(reason)
                finalize_ledger.call(:stopped)
                ctx.out.puts "\n⚠️ [Rubik::Goal] #{reason}."
                record_goal_pair.call("[Goal attempt ended after #{goal_state.step_count} steps: #{reason}]", tokens: res[:tokens])
              else
                goal_state.complete!(res[:output].to_s, tokens: res[:tokens])
                finalize_ledger.call(:completed)
                ctx.out.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
                ctx.out.puts res[:output]
                # Keep the bang syntax out of the LLM context (Plan 53 D-8): the
                # session recorder already stores the literal "!goal ..." for replay.
                record_goal_pair.call(res[:output].to_s, streamed: res[:streamed] == true, tokens: res[:tokens])

                ctx.out.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk." if ctx.buffer_manager.dirty?
              end
            else
              # Başarısızlık eşlemesi yukarıdaki tek hata kanalından akar:
              # GoalState → ledger finalize → kayıtçı çifti, istisna yoluyla
              # aynı sırayla.
              fail_goal.call(res[:error], tokens: res[:tokens], steps: res[:steps])
            end
          end
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
