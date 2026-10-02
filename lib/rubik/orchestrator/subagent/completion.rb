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
          Rubik::Storage::TranscriptIndexer.index(storage_store, inst)
          reap_orphans
          release_ready!
          # Result is deliberately absent: notices announce, the model retrieves
          # via manage_subagents wait — the wait protocol stays authoritative.
          # max_steps rides along so the budget-exhausted guidance can count.
          @event_bus&.emit(Notices::COMPLETED_EVENT, { id: inst.id, role: inst.role, state: inst.state, max_steps: inst.max_steps })
        end

        private

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
