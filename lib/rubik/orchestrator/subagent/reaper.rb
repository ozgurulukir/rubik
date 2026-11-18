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
        def archive!
          @monitor.synchronize do
            unless File.exist?(@transcript_uri.to_s)
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
        def reap_finished!(force: false)
          dropped_steering = []
          reaped = @monitor.synchronize do
            grace = reap_grace_seconds
            reaped = []
            @instances.each do |id, inst|
              next unless inst.respond_to?(:terminal_and_settled?) && inst.terminal_and_settled?
              next unless force || (grace && inst.ended_at && Time.now - inst.ended_at >= grace)
              next unless inst.archive!

              dropped_steering << id if inst.respond_to?(:pending_redeploy_messages?) && inst.pending_redeploy_messages?
              @finished[id] = inst
              reaped << id
            end
            reaped.each { |id| @instances.delete(id) }
            evict_overflow!
            reaped
          end
          # OUTSIDE the supervisor monitor (emit/logging discipline): queued
          # steering that died with the instance instead of a redeploy — the
          # send_message :queued reply discloses this, but the loss must be
          # observable (issue #55 3.2).
          Platform.debug_warn("[Reaper] reaped with undelivered queued steering: #{dropped_steering.join(', ')}") unless dropped_steering.empty?
          reaped
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

        # FIFO taşma: en eski mezar taşı evict edilir ve cleanup ile
        # :disposed'a çekilir (ctx zaten dispose'lu; cleanup no-op güvenli).
        def evict_overflow!
          while @finished.size > tombstone_limit
            _id, inst = @finished.shift
            inst&.cleanup
          end
        end
      end
    end
  end
end
