# frozen_string_literal: true

require_relative "notices"
require_relative "../auto_apply"

module Rubik
  module Orchestrator
    module Subagent
      # Supervisor'ın tamamlanma koreografisi — supervisor.rb'den çıkarıldı
      # (satır kapısı) ve bağımlılık motorunun bırakma kancası buraya
      # bağlandı: reap'ten SONRA release_ready! çalışır — kalkan slot
      # görünür, mezar taşlaşmış öncül get ile çözülebilir ve iptal
      # bildirimleri öncülün kendi tamamlanma bildiriminden önce gelir
      # (zararsız sıralama).
      module CompletionSupervisor
        def handle_subagent_completion(inst)
          merge_branch_buffer(inst) if inst.workspace == "branch" && inst.completed?
          auto_apply_subagent_buffer(inst) if inst.completed?
          retain_result(inst)
          Rubik::Storage::TranscriptIndexer.index(storage_store, inst)
          reap_orphans
          release_ready!
          # Result is deliberately absent: notices announce, the model retrieves
          # via manage_subagents wait — the wait protocol stays authoritative.
          # result_ref (issue #122) is the exception: it is the canonical,
          # execution-specific retrieval pointer the notice must carry so a
          # truncated preview always has a working continuation.
          # max_steps rides along so the budget-exhausted guidance can count.
          # storage_id: Vakanüvis kronikçisinin annal/transcript ref anahtarı
          # (plan 2026-10-04) — mevcut aboneler bu anahtarı yok sayar.
          Notices.emit(@event_bus, Notices::COMPLETED_EVENT,
                       { id: inst.id, role: inst.role, state: inst.state, max_steps: inst.max_steps,
                         storage_id: inst.storage_id, result_ref: (inst.result_ref if inst.settled?) })
        end

        private

        # The result archive's single write site (issue #122): a settled run
        # retains its redacted result under its execution-specific reference
        # (storage id + run sequence) so retrieval never needs a redeploy.
        # A retention failure degrades to a warning — the durable transcript
        # remains the fallback, and completion choreography must not stall.
        def retain_result(inst)
          return unless inst.settled? && @result_archive

          @result_archive.retain(storage_id: inst.storage_id, id: inst.id, run: inst.run_seq,
                                 state: inst.state, body: inst.result)
        rescue StandardError => e
          Rubik::Log.warn(:orchestrator, "result archive retain failed for #{inst.id}: #{e.class}: #{e.message}")
        end

        # Completion-time spelling of the shared auto-apply policy: the
        # subagents flag OR the buffer.auto_apply mode decides (previously
        # this site read the flag alone and ignored the mode), and a failed
        # apply surfaces as a notice instead of a silent rescue. The child
        # context is already disposed here, so :shell resolves from the root.
        def auto_apply_subagent_buffer(inst)
          return unless AutoApply.apply?(@config, trigger: :completion, subagent: true)

          begin
            buffer = @buffer_manager || inst.buffer_manager
            AutoApply.apply_and_sync(buffer, Rubik::Coeffects.get(@root_context, Rubik::Coeffects::SHELL))
            AutoApply.report_conflicts(@event_bus, buffer,
                                       id: inst.id, role: inst.role, state: inst.state, trigger: :completion)
          rescue StandardError => e
            AutoApply.report_failure(@event_bus, id: inst.id, role: inst.role, state: inst.state,
                                                 trigger: :completion, reason: "#{e.class}: #{e.message}")
          end
        end

        def merge_branch_buffer(inst)
          return unless inst.buffer_manager && @buffer_manager && inst.buffer_manager != @buffer_manager

          inst.buffer_manager.dirty_files.each_key do |path|
            @buffer_manager.write(path, inst.buffer_manager.read(path))
          end
        end
      end
    end
  end
end
