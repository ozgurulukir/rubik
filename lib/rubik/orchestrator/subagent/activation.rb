# frozen_string_literal: true

require_relative "../task_cancellation"

module Rubik
  module Orchestrator
    module Subagent
      # Birth choreography for EVERY subagent run — spawn and redeploy alike.
      # Extracted from supervisor.rb/reuse.rb to keep both under their
      # module-hygiene caps (the messaging.rb precedent) and, more
      # importantly, to make the unit-registration ORDERING RULE structural
      # instead of comment-enforced: the kernel unit is registered BEFORE
      # start_async at both sites, with a birth state DERIVED from instance
      # state — a unit minted while the instance is settled (the redeploy
      # entry: completed/failed) falls back to :pending, so it can never be
      # born dead. start_async's own @unit&.sync_state! is then the single
      # promotion edge (pending -> active), exactly as for fresh spawns.
      # The old dead-born trap made reap_dead_kernel_units! dispose the LIVE
      # child ctx, silently killing the ask_question channel of the
      # redeployed run (pinned by test_redeploy_registers_fresh_unit_without_state_error).
      module ActivationSupervisor
        # Call UNDER the supervisor monitor (both birth sites already ran
        # start_async under it — the worker is parked before spawn returns).
        # Order is load-bearing: coeffect provides first (coeffect resolution
        # happens at execute time, but a start_async completion must never
        # race an unprovided asker), unit registration second (pre-start, so
        # the kernel board sees a live unit), start_async last.
        def activate_instance!(inst, child_ctx:, owner_token: nil, init_supervisor: init_for_activation,
                               defer_start: false)
          # ask_question'ın subagent düzlemi: instance kendi child ctx'ine
          # asker olarak publish edilir.
          child_ctx&.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, inst)
          # send_message atfı: subagent→maestro mesajları gerçek gönderen
          # id'siyle taşır (coeffect yoksa root default'u yanlış atfı yapar).
          child_ctx&.provide(Rubik::Coeffects::SUBAGENT_SENDER_ID, inst.id)
          # Task ownership (issue #125): the spawned execution (and, through
          # inheritance, its own nested spawns) carries the owner's token; a
          # detached spawn gets a never-cancelled token so its whole subtree
          # survives a foreground ^C.
          child_ctx&.provide(Rubik::Coeffects::TASK_CANCELLATION, owner_token || TaskCancellation.detached)
          # Recheck against the fully prepared child context. Some coeffects
          # (asker, sender, cancellation) are supplied by activation itself,
          # so they cannot be resolved during the root-only preflight.
          if inst.profile_snapshot
            context = child_ctx || @root_context
            missing = inst.profile_snapshot.requires.select do |name|
              Rubik::Coeffects.get(context, name).nil?
            end
            raise UnsatisfiedCoeffectsError.new(inst.profile_snapshot.name, missing) unless missing.empty?
          end

          eff_init = init_supervisor
          if defer_start && eff_init && !eff_init.respond_to?(:unregister)
            raise ArgumentError,
                  "Transactional subagent activation requires an init supervisor with #unregister."
          end

          if eff_init
            unit = Kernel::SubagentUnit.new(inst, context: child_ctx, birth_state: unit_birth_state(inst))
            eff_init.register(unit)
          end
          inst.start_async(defer_start: defer_start) { |completed_inst| handle_subagent_completion(completed_inst) }
          inst
        end

        def init_for_activation
          @init || (@root_context.respond_to?(:get) && Rubik::Coeffects.get(@root_context, Rubik::Coeffects::INIT))
        end
        private :init_for_activation

        # Child-ctx mint + the one degrade warning. A root context without
        # #extend (duck-type host) cannot carry the question/sender
        # coeffects — the degradation is made visible, never silent.
        def extend_root_context!(origin)
          child_ctx = @root_context.respond_to?(:extend) ? @root_context.extend : nil
          Rubik::Log.warn(:orchestrator, "subagent #{origin}: root context lacks #extend — no child ctx; subagent planes degrade") unless child_ctx
          child_ctx
        end

        private

        # The registration-order rule, DERIVED FROM INSTANCE STATE: a unit is
        # born with a LIVE kernel state, never a terminal one. If the
        # instance's current state maps through STATE_MAP into a terminal
        # unit state (the redeploy entry: completed/failed), mint :pending
        # instead — start_async's own @unit&.sync_state! (instance.rb) is
        # then the single promotion edge. A born-:pending unit settling
        # forward is a legal Unit#transition_to! edge; a born-terminal unit
        # is frozen forever (sync_state! no-ops on dead).
        def unit_birth_state(inst)
          derived = Kernel::SubagentUnit::STATE_MAP.fetch(inst.state)
          Kernel::Unit::TERMINAL_STATES.include?(derived) ? :pending : derived
        end
      end
    end
  end
end
