# frozen_string_literal: true

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
        def archived? = !!@archived

        # History yalnız transcript diske DURABLY yazıldıysa silinir —
        # dosya yoksa reap sonraki süpürmeye kalır (yarım tasfiye yok).
        def archive!
          @monitor.synchronize do
            return false unless File.exist?(@transcript_uri.to_s)

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
          @monitor.synchronize do
            grace = reap_grace_seconds
            reaped = []
            @instances.each do |id, inst|
              next unless inst.respond_to?(:terminal_and_settled?) && inst.terminal_and_settled?
              next unless force || (grace && inst.ended_at && Time.now - inst.ended_at >= grace)
              next unless inst.archive!

              (@finished ||= {})[id] = inst
              reaped << id
            end
            reaped.each { |id| @instances.delete(id) }
            evict_overflow!
            reaped
          end
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
          raw = @config.respond_to?(:fetch) ? @config.fetch("subagents.reap_finished_after", 300) : 300
          raw = 300 if raw.nil?
          raw.to_f <= 0 ? nil : raw.to_f
        end

        def tombstone_limit
          raw = @config.respond_to?(:fetch) ? @config.fetch("subagents.tombstone_limit", 25) : 25
          raw = 25 if raw.nil?
          raw.to_i
        end

        # FIFO taşma: en eski mezar taşı evict edilir ve cleanup ile
        # :disposed'a çekilir (ctx zaten dispose'lu; cleanup no-op güvenli).
        def evict_overflow!
          return unless @finished

          while @finished.size > tombstone_limit
            _id, inst = @finished.shift
            inst&.cleanup
          end
        end
      end
    end
  end
end
