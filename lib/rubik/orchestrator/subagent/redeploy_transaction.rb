# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # The redeploy entry's supervisor-plane support: refusal reasons, the
      # root-coeffect preflight, the SS release hook, and the spawn-parity
      # transaction rollback (rollback_spawn! family, spawn_transaction.rb).
      # The irreversible step — redeploy_for!'s history append + inbox
      # drain — is NOT reverted; rollback restores PLACEMENT atomicity only:
      # unit registration, roster placement, the fresh child ctx. The
      # instance stays terminal-and-settled; a retry re-appends one
      # "[New task]" line — bounded, benign.
      #
      # from_finished note: reaping archives before tombstoning, and archived
      # instances refuse redeploy — a tombstoned lookup serves only the refusal
      # message. The restoration arm is drift defense for future reap semantics.
      module RedeployTransaction
        # SS bırakma kancası (spawn ile aynı düzen): başarılı redeploy'un
        # SONRASINDAKİ süpürme hatası, zaten koşan transaction'ı fail
        # etmesin — spawn'ın "release failed after successful spawn"
        # warn-paritesi.
        def release_ready_after_redeploy!
          release_ready!
        rescue StandardError => e
          Rubik::Log.warn(:orchestrator,
                          "subagent dependency release failed after successful redeploy (#{e.class}: #{e.message})")
        end

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

        # Spawn preflights this before any reservation (resolve_profile_snapshot);
        # redeploy discovered the same failure only in activate_instance! —
        # i.e. AFTER the irreversible instance mutation. Root coeffects are
        # checked against the root context; activation's own provides
        # (asker/sender/cancellation) are exempt.
        def preflight_redeploy_coeffects!(profile, type_name:)
          unless profile
            raise ReservedProfileError,
                  "No subagent archetype is available for '#{type_name}' (removed from the registry since spawn?)."
          end

          missing = (profile.requires || []).reject do |name|
            SpawnSupervisor::CHILD_CONTEXT_COEFFECTS.include?(name) ||
              !Rubik::Coeffects.get(@root_context, name).nil?
          end
          raise UnsatisfiedCoeffectsError.new(profile.name, missing) unless missing.empty?
        end

        # pre_existing_unit: the unit owned by the PREVIOUS lifecycle (if any).
        # Only a unit this transaction minted (identity differs) is unregistered
        # — a pre-mint failure must not desync the kernel board by stripping
        # the historical unit the supervisor never touched here.
        def rollback_redeploy!(inst:, child_ctx:, from_finished:, init_supervisor:, pre_existing_unit:)
          if inst.unit && !inst.unit.equal?(pre_existing_unit) && init_supervisor.respond_to?(:unregister)
            begin
              init_supervisor.unregister(inst.unit)
            rescue StandardError => e
              Rubik::Log.warn(:orchestrator,
                              "subagent redeploy unit rollback failed for '#{inst.id}' (#{e.class}: #{e.message})")
            end
          end

          begin
            inst.fail_turn!("redeploy activation failed: worker could not start") unless inst.settled? || inst.disposed?
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator,
                            "subagent redeploy state rollback failed for '#{inst.id}' (#{e.class}: #{e.message})")
          end

          # Restore the tombstone the deletion removed. For an @instances
          # origin the map moves were no-ops — deleting here would LOSE
          # the instance instead of restoring placement.
          @instances.delete(inst.id) if from_finished && @instances[inst.id].equal?(inst)
          @finished[inst.id] = inst if from_finished

          begin
            child_ctx&.dispose
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator,
                            "subagent redeploy context rollback failed for '#{inst.id}' (#{e.class}: #{e.message})")
          end
          nil
        end
      end
    end
  end
end
