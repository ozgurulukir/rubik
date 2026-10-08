# frozen_string_literal: true

module Rubik
  module MCP
    # Boot state-machine vocabulary for Rubik::MCP::Manager (included there).
    # Storage stays on the host: @statuses, @boot_marks, @clients and @monitor
    # are Manager ivars these paths touch on `self`, always under that
    # monitor (Ruby Monitor is re-entrant, so callers already holding it
    # compose freely). Thread-safety fence (mcp-async-boot G5): none of these
    # paths block on threads or I/O — the boot-thread join stays outside the
    # monitor.
    #
    # Precedent: orchestrator/subagent/lifecycle.rb — a pure state machine
    # deserves its own page, not headroom to grow back.
    module BootLifecycle
      # Raised by transition_server! on an edge outside TRANSITIONS. The
      # table is derived from the actual write sites, so this firing means a
      # new writer skipped the guarded seam (fail-loud tripwire).
      class StateError < StandardError; end

      STATES = [:disabled, :connecting, :active, :failed].freeze

      # Every legal from->to edge, derived from the write sites:
      #   disabled   <- add_server (auto_start false / disabled config),
      #                 disable_server (user teardown wins from ANY state),
      #                 re-add over a failed/connecting slot
      #   connecting <- boot phase-0 claim over :disabled, :failed (re-boot),
      #                 or :active-with-dead-client (already_active misses)
      #   active     <- apply success (boot path from :connecting; enable
      #                 path from :disabled/:failed), user enable during a
      #                 boot (:connecting)
      #   failed     <- apply rollback, enable connect failure (from
      #                 :disabled, :failed retry, :active dead-client,
      #                 :connecting), boot's epoch-guarded connect-failure
      #                 flip and D6 ensure sweep
      # The table is fully connected — that IS the invariant: user decisions
      # are legal from any state; boot writes are legal only from an
      # epoch-owned :connecting. Server absence (remove_server) is not a
      # state, it is record deletion (clear_server_record!).
      TRANSITIONS = {
        disabled: [:connecting, :active, :failed],
        connecting: [:active, :failed, :disabled],
        active: [:disabled, :connecting, :failed],
        failed: [:connecting, :active, :disabled]
      }.transform_values(&:freeze).freeze

      # The only mutation path for @statuses. epoch: nil is the USER actor —
      # the decision wins from any state (D5). Passing epoch: makes it the
      # BOOT actor: it owns the slot only while the slot is still :connecting
      # under ITS epoch; anything else (user disable/enable/remove, a newer
      # boot's fresh mark) wins, and the call is a silent no-op returning
      # nil. Idempotent on same-state (returns the current state); raises
      # StateError on an edge outside TRANSITIONS. Epoch gate and flip are
      # applied in the SAME monitor hold — never split this into a predicate
      # read followed by an unguarded write.
      def transition_server!(name, to, epoch: nil)
        name = name.to_s
        @monitor.synchronize do
          current = @statuses[name] || :disabled
          target = to.to_sym
          return current if current == target

          return nil if epoch && (current != :connecting || !@boot_marks[name].equal?(epoch))

          raise StateError, "illegal MCP boot transition '#{name}': #{current} -> #{target}" unless TRANSITIONS.fetch(current, []).include?(target)

          @statuses[name] = target
          # Boot-mark debt: a mark only matters while :connecting. Leaving
          # the state retires it, so marks never outlive their epoch
          # (zero-restart — claim/apply and claim/remove cycles keep
          # @boot_marks flat instead of growing forever).
          @boot_marks.delete(name) unless target == :connecting
          target
        end
      end

      # Phase-0 claim: returns true when a live :active server already owns
      # the slot (boot must not touch it); otherwise flips the slot to
      # :connecting and tags it with this boot's epoch — atomically under one
      # monitor hold (D5). A re-claim over a stale :connecting mark (wedged
      # older boot) takes the slot over with the new epoch.
      def claim_boot_slot!(name, epoch)
        name = name.to_s
        @monitor.synchronize do
          already_active = @statuses[name] == :active && @clients[name]&.running?
          unless already_active
            transition_server!(name, :connecting) # re-entrant: same hold
            @boot_marks[name] = epoch
          end
          already_active
        end
      end

      # remove_server's record deletion: status and (possibly dead) boot mark
      # retire together — deletion must not leave a mark for a slot that no
      # longer exists.
      def clear_server_record!(name)
        name = name.to_s
        @monitor.synchronize do
          @statuses.delete(name)
          @boot_marks.delete(name)
        end
      end

      # Stop-debt rule, structural (was prose in perform_load_from_config
      # plus the [:failed, true].include? arithmetic): an applied or
      # failed-apply slot stopped its own client (context drain / rollback);
      # skipped and never-ran slots still owe a stop in the ensure.
      def self.owes_stop?(outcome)
        !outcome.equal?(:applied) && !outcome.equal?(:failed)
      end
    end
  end
end
