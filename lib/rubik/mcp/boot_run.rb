# frozen_string_literal: true

module Rubik
  module MCP
    # One boot run (issue #453): the mutable state of a single
    # perform_load_from_config invocation — entries / connected / outcomes /
    # boot_epoch — plus the five named phases that consume it, moved
    # verbatim from Manager's former parameter-threaded phase methods. The
    # outcomes ledger is an explicit atom map (index -> :applied | :failed;
    # absence = skipped or never ran — exactly what owes_stop? reads).
    #
    # Friend-class seam: Manager keeps its guarded internals private, so
    # BootRun reaches them through send (the public seams — add_server,
    # connect_server, apply_connected_server, transition_server!, the
    # BootLifecycle claim, and the client() reader — are called directly).
    # Every monitor-hold boundary and epoch gate below is the former inline
    # code relocated, not restructured: the atomic-rollback doctrine lives
    # in run's ensure choreography plus BootLifecycle's epoch machinery.
    class BootRun
      attr_reader :entries, :connected, :outcomes, :boot_epoch

      def initialize(manager, servers_cfg, mcp_enabled)
        @manager = manager
        @servers_cfg = servers_cfg
        @mcp_enabled = mcp_enabled
        # Boot epoch (review round): :connecting marks carry a per-invocation
        # identity so a wedged older boot can never downgrade a newer mark.
        @boot_epoch = Object.new
        @entries = []
        @connected = []
        @outcomes = {}
      end

      # Choreography: register first (phase 0 fails per server without
      # orphaning anything), then ONE ensure spans both post-registration
      # phases — phase 1 deliberately did no context wiring, so stopping
      # the client is the ONLY cleanup an unapplied prepared slot owes (no
      # orphaned child processes, even when an interrupt lands mid-boot).
      # The begin/ensure boundary is verbatim from the former body: a
      # register! failure never triggers the sweeps, exactly as before.
      def run
        register!
        begin
          connect!
          apply!
        ensure
          rollback_unapplied!
          fail_orphans!
        end
        nil
      end

      private

      # Phase 0 (sequential, config order): registration still goes
      # through add_server — subclasses and plugins wrap that seam, and a
      # broken definition must fail exactly as before (logged, skipped,
      # not half-registered). auto_start is deliberately false here: the
      # connect half moved to the fan-out. Ends each auto-start candidate
      # with the phase-0 claim (D5).
      def register!
        @servers_cfg.each do |sname, sdefn|
          next unless sdefn.is_a?(Hash)

          auto_start = @mcp_enabled && (sdefn.fetch("enabled", true) != false)
          begin
            @manager.add_server(sname, sdefn, auto_start: false, persist: nil)
          rescue StandardError => e
            # ENSURE-LOG (G3 round-1): one broken server config used to
            # vanish behind an ENV["RUBIK_DEBUG"] gate; a misconfigured
            # server must surface without debug mode.
            Rubik::Log.warn(:mcp, "failed to load MCP server '#{sname}' (#{e.class}: #{e.message})")
            @manager.send(:emit_mcp_event, :mcp_server_failed, :err, sname.to_s, error: e.message)
            next
          end
          next unless auto_start

          name_str = sname.to_s
          # Phase-0 claim (D5): check+mark in ONE monitor hold — a user
          # enable/disable/remove that races the boot reads a definite
          # state, and phase 2's gate below can never miss a window.
          @entries << [name_str, sdefn.transform_keys(&:to_s)] unless @manager.claim_boot_slot!(name_str, @boot_epoch)
        end
      end

      # Phase 1 (fan-out): pure I/O connects. Slots are captured by SIDE
      # EFFECT inside the item blocks: when an Exception-level error (a
      # boot interrupt) kills .map before it returns, the assignment below
      # never happens — a value-only `connected` would leave the ensure
      # blind to every successfully-started client. Hence the pre-built
      # array owned here rather than a returned value.
      def connect!
        @connected = ::Array.new(@entries.size)
        return if @entries.empty?

        Rubik::Concurrency.map(@entries.each_with_index.to_a) do |(name_str, parsed_defn), index|
          @connected[index] = { ok: true, **@manager.connect_server(name_str, parsed_defn) }
        rescue StandardError => e
          @connected[index] = { ok: false, error: e }
        end
      end

      # Phase 2 (sequential, config order): apply state; identical
      # per-server warning on either phase's failure.
      def apply!
        @entries.each_with_index do |(name_str, parsed_defn), index|
          slot = @connected[index]
          next unless slot # never connected (interrupt during phase 1)

          if slot[:ok]
            begin
              outcome = @manager.send(:boot_apply_gate, name_str, parsed_defn, @boot_epoch,
                                      client: slot[:client], tools: slot[:tools])
              @outcomes[index] = :applied if outcome == :applied
              if outcome == :applied
                @manager.send(:emit_mcp_event, :mcp_server_loaded, :info, name_str,
                              tools: @manager.send(:tool_count, name_str))
              end
            rescue StandardError => e
              # ENSURE-LOG (G3 round-1): one broken server config used to
              # vanish behind an ENV["RUBIK_DEBUG"] gate; a misconfigured
              # server must surface without debug mode. apply's own
              # rollback already set :failed and stopped its client via
              # the context drain; :failed marks the slot so the ensure
              # never double-stops it.
              @outcomes[index] = :failed
              Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{e.class}: #{e.message})")
              @manager.send(:emit_mcp_event, :mcp_server_failed, :err, name_str, error: e.message)
            end
          else
            # Only our own epoch's mark may flip to :failed — a user
            # disable/remove during the handshake, or a newer boot's fresh
            # mark, must win over this boot's connect failure (D5). The
            # epoch gate and flip happen in the same monitor hold inside
            # transition_server!.
            @manager.transition_server!(name_str, :failed, epoch: @boot_epoch)
            error = slot[:error]
            Rubik::Log.warn(:mcp, "failed to load MCP server '#{name_str}' (#{error.class}: #{error.message})")
            @manager.send(:emit_mcp_event, :mcp_server_failed, :err, name_str, error: error.message)
          end
        end
      end

      # Ensure part 1: stop every prepared client that did not end up
      # registered: a failed apply already rolled its own client back via
      # the context drain, while a never-applied one (interrupt between
      # phases) owes a stop here. A :skipped slot also owes a stop —
      # skipping the APPLY must not orphan its prepared child process (that
      # is the exact leak D10 closed for handshakes). owes_stop? is the
      # structural form of that rule: skipped and never-ran slots owe.
      def rollback_unapplied!
        @entries.each_with_index do |(name_str, _defn), index|
          slot = @connected[index]
          next if !slot.is_a?(Hash) || !slot[:client] || !owes_stop?(index)

          registered = @manager.client(name_str)
          next if registered.equal?(slot[:client])

          begin
            slot[:client].stop
          rescue StandardError => e
            Rubik::Log.warn(:mcp, "failed to stop unapplied MCP server '#{name_str}' (#{e.class}: #{e.message})")
          end
        end
      end

      # The named form of the outcomes-ledger absence rule ("absence = owes
      # stop"): an index missing from the ledger means the slot was skipped
      # or never ran, and both owe a stop in the ensure. Delegates the
      # per-outcome rule to BootLifecycle.owes_stop? so the stop-debt rule
      # keeps one home; the ledger only ever records :applied / :failed, so
      # absence is exactly the owes case — behavior-identical to the former
      # inline BootLifecycle.owes_stop?(outcomes[index]) read.
      def owes_stop?(index)
        BootLifecycle.owes_stop?(@outcomes[index])
      end

      # Ensure part 2 — terminal state for boot entries that never reached
      # apply (D6): anything still :connecting failed to boot; user-chosen
      # values (:disabled, :active, deleted-by-remove) are left untouched.
      # The epoch check inside transition_server! keeps an older wedged
      # boot's sweep from downgrading a newer boot's fresh mark.
      def fail_orphans!
        @entries.each do |(name_str, _defn)|
          @manager.transition_server!(name_str, :failed, epoch: @boot_epoch)
        end
      end
    end
  end
end
