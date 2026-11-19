# frozen_string_literal: true

require_relative "../../log"
require_relative "../../platform"
require_relative "../../storage/layout"

module Rubik
  module Orchestrator
    module Subagent
      # Özenli tasfiye (diligent reaping): işi biten subagent'lar grace
      # süresi sonunda mezar taşına (tombstone) taşınır — bellekteki
      # history serbest bırakılır, dayanıklı transcript ve storage indeksi
      # kalır, status sorgulanabilir. :budget_exhausted / :paused_error
      # ASLA reap edilmez: thread canlıdır (condvar park), resume hakları
      # bozulmaz.
      module Reaper
        # Bounded transcript-save retry policy (#553): a failed save! returns
        # nil and leaves no file, which previously made archive! return false
        # forever — the instance was unreapable and its history leaked. After
        # this many failed sweeps we reap WITH A WARNING; the save failure is
        # still observable via last_error, and liveness beats a stuck tombstone.
        TRANSCRIPT_ARCHIVE_MAX_RETRIES = 3

        def archived? = !!@archived

        # History yalnız transcript diske DURABLY yazıldıysa silinir —
        # dosya yoksa reap sonraki süpürmeye kalır (yarım tasfiye yok). After
        # TRANSCRIPT_ARCHIVE_MAX_RETRIES the durability gate is released with
        # a warning so a permanently-failing save cannot strand the instance.
        # `durable:` lets the supervisor sweep pre-probe the transcript OUTSIDE
        # its monitor (issue #595-5) and hand the verdict in; nil probes here
        # (legacy direct callers keep the retry semantics untouched).
        def archive!(durable: nil)
          @monitor.synchronize do
            exists = durable.nil? ? File.exist?(@transcript_uri.to_s) : durable
            unless exists
              @archive_retries = (@archive_retries || 0) + 1
              if @archive_retries < TRANSCRIPT_ARCHIVE_MAX_RETRIES
                return false # transient: leave it for the next sweep
              end

              Rubik::Log.warn(:orchestrator,
                              "[Reaper] reaping #{@id} without a durable transcript after #{@archive_retries} attempts " \
                              "(last_error: #{@last_error.inspect})")
            end

            @history.replace([])
            @archived = true
            true
          end
        end
      end

      # Supervisor düzlemi: tombstone haritası + otomatik/force süpürme.
      # Tombstone'lar get/list üzerinden sorgulanabilir kalır; wait_for
      # bilinçli olarak yalnız @instances'e bakar (reap edilen zaten
      # notice ile duyurulmuş, sonucu transcriptte).
      module ReaperSupervisor
        # Three-pass sweep (issue #595-5): the supervisor monitor is held
        # only for STATE BOOKKEEPING. Pass 1 snapshots the candidates and
        # releases the lock; the transcript durability probes (File.exist?)
        # and the tombstone cleanups run OUTSIDE it, so spawn/send_message/
        # status are never stalled behind FS IO. Pass 2 keeps archive! UNDER
        # the monitor on purpose: the redeploy plane shares this monitor
        # exactly so an archive cannot interleave a redeployable? check
        # (reuse.rb buffer_for_redeploy) — that invariant is not negotiable.
        def reap_finished!(force: false)
          grace = reap_grace_seconds
          candidates = @monitor.synchronize do
            @instances.values.select do |inst|
              next unless inst.respond_to?(:terminal_and_settled?) && inst.terminal_and_settled?

              force || (grace && inst.ended_at && Time.now - inst.ended_at >= grace)
            end
          end
          # OUTSIDE the supervisor monitor: per-candidate transcript probe.
          durability = candidates.to_h { |inst| [inst.id, File.exist?(inst.transcript_uri.to_s)] }

          dropped_steering = []
          reaped_ids = evicted = nil
          @monitor.synchronize do
            reaped_ids = []
            evicted = []
            candidates.each do |inst|
              # Re-checks (redeploy may have revived it between the passes);
              # archive! + tombstone move stay atomic against the redeploy
              # plane by sharing this monitor.
              next unless @instances[inst.id].equal?(inst) && inst.terminal_and_settled?
              next unless inst.archive!(durable: durability[inst.id])

              dropped_steering << inst.id if inst.respond_to?(:pending_redeploy_messages?) && inst.pending_redeploy_messages?
              @finished[inst.id] = inst
              reaped_ids << inst.id
            end
            reaped_ids.each { |id| @instances.delete(id) }
            evicted = evict_overflow!
          end
          # OUTSIDE the supervisor monitor: tombstone overflow cleanup
          # (context dispose) must not stall live-plane operations.
          evicted.each(&:cleanup)
          # OUTSIDE the supervisor monitor (emit/logging discipline): queued
          # steering that died with the instance instead of a redeploy — the
          # send_message :queued reply discloses this, but the loss must be
          # observable (issue #55 3.2).
          Platform.debug_warn("[Reaper] reaped with undelivered queued steering: #{dropped_steering.join(', ')}") unless dropped_steering.empty?
          reaped_ids
        end

        private

        # reap_orphans gövdesinden çağrılır (handle_subagent_completion'ın
        # hazır kancası) — disposed kabukları at, sonra grace dolanları
        # tombstone'la. Tamamen sessiz bir oturumda SON biten subagent
        # hiçbir tamamlanma tetikleyicisi bulamaz: sınırlı kalıntı, force
        # ile elle reap edilebilir.
        def sweep_disposed_and_finished
          @instances.delete_if { |_k, v| v.disposed? }
          reap_finished!
        end

        def reap_grace_seconds
          raw = Rubik::Storage::Layout.config_get(@config, "subagents.reap_finished_after", 300)
          raw.to_f <= 0 ? nil : raw.to_f
        end

        def tombstone_limit
          Rubik::Storage::Layout.config_get(@config, "subagents.tombstone_limit", 25).to_i
        end

        # FIFO taşma: en eski mezar taşları evict edilir ve CALLING SIDE'a
        # döner — cleanup (:disposed'a çekme, context dispose) monitor
        # DIŞINDA çalışır (issue #595-5).
        def evict_overflow!
          evicted = []
          while @finished.size > tombstone_limit
            _id, inst = @finished.shift
            evicted << inst if inst
          end
          evicted
        end
      end
    end
  end
end
