# frozen_string_literal: true

require_relative "reaper"

module Rubik
  module Orchestrator
    module Subagent
      # Subagent reuse (context preserved redeploy): bitmiş bir subagent'a
      # (completed/failed, thread ölmüş) aynı kimlik ve birikmiş LLM
      # history'si ile YENİ görev verilir — taze spawn + yeniden açıklama
      # maliyeti yok. maestro doktrininin temel taşı.
      module Redeploy
        # Sadece terminal VE thread'i ölmüş stateler: ölü thread, run'ın
        # ensure bloğunun (save_transcript! → cleanup_context →
        # on_complete) TAMAMEN çalıştığını kanıtlar — redeploy kendi
        # tamamlanma işleyişiyle yarışamaz. settled? = :completed/:failed
        # (Instance'ın lifecycle sözlüğü); :disposed bilinçli dışarıda.
        def terminal_and_settled?
          settled? && !@thread&.alive?
        end

        def redeployable?
          terminal_and_settled? && !@archived
        end

        # Issue #55 3.2 buffer: a steering message for a finished-but-unreaped
        # instance. Check and push under ONE monitor acquisition — the
        # reaper's archive! shares this monitor, so an archive between a
        # redeployable? check and the push (which would strand the message
        # in a wiped history) cannot interleave. No grant branches here: the
        # redeploy mints a fresh budget, and a settled instance must not
        # resurrect.
        def buffer_for_redeploy(message, sender: nil)
          @monitor.synchronize do
            return false unless redeployable?

            @inbox.push(Instance::InboxMessage.new(message, sender))
            true
          end
        end

        # Operator diagnostics for the reap path: queued steering that died
        # with the instance instead of being delivered by a redeploy.
        def pending_redeploy_messages?
          @monitor.synchronize { !@inbox.empty? }
        end

        # Sadece sıfırlama — @state'i ASLA çevirme; :running flip'i ve
        # thread başlatmayı start_async sahiplenir (flip-sonrası-start
        # hatası penceresi olmasın). Budget taze mint edilir (bitmiş
        # run'ın exhausted bayrağı taşıyabilir), ölü child ctx yerine yenisi
        # ve taze scoped registry bağlanır (eskisinin ask_question'ı
        # dispose'lu ctx'e rebind'lıydı). Yeni görev history'ye user
        # mesajı olarak eklenir; run cycle yalnız BOŞ history seed eder.
        def redeploy_for!(prompt:, max_steps:, context:, tool_registry:, owner_task: nil)
          @monitor.synchronize do
            return false unless redeployable?

            drain_inbox_into_history
            @history << { role: "user", content: "[New task from maestro]: #{prompt}" }
            @prompt = prompt.to_s
            @budget = Budget.new(max_steps: max_steps.to_i, max_total_steps: @budget.max_total_steps)
            # @result reset is the ONE sanctioned clearer (terminal-only
            # contract): a new lineage begins. @pause_facts rides along —
            # the old run's wait fact must not narrate the new one.
            @result = @last_error = @ended_at = @transcript_path = nil
            @pause_facts = nil
            # Task ownership (issue #125): the redeployed run belongs to the
            # CURRENT task's token (or stays detached); a fresh lineage is not
            # born "cancelled by operator". Operation telemetry (#126) starts
            # clean with it — no stale operation survives a redeploy.
            @owner_task = owner_task
            @cancelled_by_operator = false
            @operations.reset!
            @context = context
            @tool_registry = tool_registry
            @context_cleaned_up = false
            true
          end
        end
      end

      # Supervisor düzlemi: spawn'ın coeffect koreografisini (child ctx,
      # scoped registry, asker provide, SubagentUnit register, start_async)
      # ActivationSupervisor TEK seam'den oynatır — spawn ile birebir aynı
      # düzen: unit kaydı start_async'DEN ÖNCE, derived birth state ile
      # (settled girişte :pending; ölü-doğan unit tuzağı yapısal olarak
      # imkânsız — bkz. activation.rb). provider/buffer/provider_gate/
      # storage_id/kimlik AYNEN KALIR (reuse'un kendisi bu).
      module RedeploySupervisor
        # `owner: :keep` (the default) keeps the instance's existing task
        # ownership; the tool plane passes the CURRENT turn's token so a
        # redeploy issued in this turn is cancellable with it (issue #125).
        def redeploy(id, prompt:, max_steps: nil, owner: :keep)
          prompt_str = prompt.to_s.strip
          raise ArgumentError, "Redeploy prompt cannot be empty" if prompt_str.empty?

          redeployed = @monitor.synchronize do
            key = id.to_s
            inst = @instances[key] || (@finished || {})[key]
            raise ArgumentError, redeploy_refusal(key, inst) unless inst&.redeployable?

            eff_owner = owner == :keep ? inst.owner_task : owner
            refute_cancelled_owner!(eff_owner)
            validate_concurrency!
            child_ctx = extend_root_context!(:redeploy)
            profile = inst.profile_snapshot || @type_registry.get(inst.type_name)
            scoped_registry = build_scoped_registry(profile, child_ctx, inst.buffer_manager)
            return false unless inst.redeploy_for!(prompt: prompt_str, max_steps: (max_steps || @default_max_steps).to_i,
                                                   context: child_ctx, tool_registry: scoped_registry,
                                                   owner_task: eff_owner)

            @finished&.delete(inst.id)
            @instances[inst.id] = inst
            activate_instance!(inst, child_ctx: child_ctx, owner_token: eff_owner)
          end
          # Start-to-Start (SS) bırakma kancası: redeploy da bir başlangıçtır — taze :running
          # flip'i, bu id'yi Start-to-Start (SS) ile bekleyen kuyruk spesifikasyonlarını
          # bırakır (kilit DIŞINDA — emit kuralı; spawn ile aynı düzen).
          release_ready!
          redeployed
        end

        private

        # Reddetme gerekçesi durum-bazlı yönlendirme içerir: maestro doğru
        # aksiyona (steer / wait / taze spawn) yönelsin.
        def redeploy_refusal(id, inst)
          return "Subagent '#{id}' not found." unless inst
          return "Subagent '#{id}' is archived (reaped) — spawn a fresh subagent via invoke_subagent." if inst.archived?

          if inst.settled?
            "Subagent '#{id}' is still settling (completion handling in flight); retry shortly."
          else
            "Subagent '#{id}' is #{inst.state} with a live thread — steer it (send_message / extend_budget) or kill it first."
          end
        end
      end
    end
  end
end
