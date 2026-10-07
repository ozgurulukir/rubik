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
        def redeploy_for!(prompt:, max_steps:, context:, tool_registry:)
          @monitor.synchronize do
            return false unless redeployable?

            drain_inbox_into_history
            @history << { role: "user", content: "[New task from maestro]: #{prompt}" }
            @prompt = prompt.to_s
            @budget = Budget.new(max_steps: max_steps.to_i)
            @result = @last_error = @ended_at = @transcript_path = nil
            @context = context
            @tool_registry = tool_registry
            @context_cleaned_up = false
            true
          end
        end
      end

      # Supervisor düzlemi: spawn'ın coeffect koreografisini (child ctx,
      # scoped registry, asker provide, SubagentUnit register, start_async)
      # yeniden oynatır. provider/buffer/provider_gate/storage_id/kimlik
      # AYNEN KALIR (reuse'un kendisi bu). Taze SubagentUnit start_async'DEN
      # SONRA register edilir: daha önce register edilirse instance hâlâ
      # terminal olduğundan unit ÖLÜ doğar (sync_state! dead'de no-op) ve
      # her turda çalışan reap_dead_kernel_units! CANLI child ctx'i dispose
      # ederdi — ask_question kanalı redeploy run'ında sessizce düşerdi.
      module RedeploySupervisor
        def redeploy(id, prompt:, max_steps: nil)
          prompt_str = prompt.to_s.strip
          raise ArgumentError, "Redeploy prompt cannot be empty" if prompt_str.empty?

          @monitor.synchronize do
            key = id.to_s
            inst = @instances[key] || (@finished || {})[key]
            raise ArgumentError, redeploy_refusal(key, inst) unless inst&.redeployable?

            validate_concurrency!
            child_ctx = @root_context.respond_to?(:extend) ? @root_context.extend : nil
            Rubik::Log.warn(:orchestrator, "subagent redeploy: root context lacks #extend — no child ctx; subagent planes degrade") unless child_ctx
            scoped_registry = build_scoped_registry(@type_registry.get(inst.type_name), child_ctx, inst.buffer_manager)
            return false unless inst.redeploy_for!(prompt: prompt_str, max_steps: (max_steps || @default_max_steps).to_i,
                                                   context: child_ctx, tool_registry: scoped_registry)

            @finished&.delete(inst.id)
            @instances[inst.id] = inst
            child_ctx&.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, inst)
            # Redeploy TAZE child ctx basar: asker gibi gönderen atfı da
            # yeniden sağlanmalı — yoksa mesajlar agent-0'a geri atfedilir.
            child_ctx&.provide(Rubik::Coeffects::SUBAGENT_SENDER_ID, inst.id)
            inst.start_async { |completed_inst| handle_subagent_completion(completed_inst) }
            eff_init = @init || (@root_context.respond_to?(:get) && Rubik::Coeffects.get(@root_context, Rubik::Coeffects::INIT))
            eff_init&.register(Rubik::Kernel::SubagentUnit.new(inst, context: child_ctx))
            inst
          end
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
