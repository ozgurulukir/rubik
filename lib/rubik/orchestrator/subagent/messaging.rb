# frozen_string_literal: true

require_relative "../../platform"
require_relative "notices"
require_relative "conversation_id"

module Rubik
  module Orchestrator
    module Subagent
      # Inter-agent messaging (Plan 94 + issue #55 3.2): supervisor-plane
      # delivery for SendMessageTool. Extracted from supervisor.rb to keep
      # the file under its module-hygiene cap; the supervisor delegates
      # send_message here. Root recipient aliases live in conversation_id.rb
      # (root plane alias resolution is referenced by tool reply text too).
      module MessagingSupervisor
        # Returns true (delivered to an active instance), :queued (buffered
        # on a finished-but-unreaped instance — drain_inbox_into_history
        # delivers it when that id is redeployed), or false (unknown /
        # disposed / reaped-mid-flight recipient). The completion→reap
        # window used to reject steering outright while redeploy on the same
        # id succeeded (issue #55 3.2); buffering closes it. The buffer is
        # monitor-atomic against the reaper (buffer_for_redeploy), and
        # posting to a settled instance cannot resurrect it (pinned by
        # test_dead_instance_must_not_resurrect_via_post_message).
        def send_message(recipient_id, message, sender_id: ConversationId::ROOT_ID, additional_steps: nil, **kwargs)
          rec = ConversationId.scrub(recipient_id)
          eff_sender = kwargs[:_sender_id] || sender_id
          if ConversationId.root_alias?(rec)
            Notices.emit(@event_bus, Notices::MESSAGE_EVENT, { sender_id: eff_sender, recipient: rec, message: message })
            return true
          end

          inst = get(rec)
          return false unless inst

          if inst.deliverable?
            inst.post_message(message, sender: eff_sender, additional_steps: additional_steps)
            return true
          end

          # get's queue fallback can also surface a DeferredSpec (a not-yet-
          # born dependency-queued spec): nothing to buffer onto, nothing to
          # redeploy — undeliverable.
          return false unless inst.respond_to?(:buffer_for_redeploy)

          # Finished-but-unreaped recipient: buffer into the inbox —
          # redeploy's drain_inbox_into_history delivers it. Steps grants
          # are meaningless here (redeploy mints a fresh budget). A race
          # loss (reaper archived the instance between the checks) reports
          # false instead of a stranded :queued.
          if inst.buffer_for_redeploy(message, sender: eff_sender)
            :queued
          else
            Platform.debug_warn("[Supervisor] steering message for '#{rec}' lost: reaped between liveness checks")
            false
          end
        end
      end
    end
  end
end
