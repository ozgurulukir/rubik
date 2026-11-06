# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "subagent" # SubagentToolHelpers (supervisor resolution)
require_relative "../../coeffects"
require_relative "../../orchestrator/subagent/conversation_id"

module Rubik
  module Tools
    # Tool for inter-agent messaging between supervisor and subagents (Plan 94).
    # The subagent plane rebinds this tool to the child ctx (ScopedRegistry),
    # so a subagent messaging the maestro carries its REAL sender id; the root
    # plane keeps the machine default sender (agent-0).
    class SendMessageTool < BaseTool
      include SubagentToolHelpers

      DECLARATION = Declaration.new(
        name: "send_message", aliases: ["msg_agent", "tell_subagent"],
        description: "Send a message or instruction to another agent or subagent by its conversation ID.",
        risk: :execute, maestro_blocked: false, # steering plane — pointing the orchestrator's workers is orchestration
        params_schema: {
          type: "object",
          properties: {
            recipient: { type: "string", description: "The recipient subagent conversation ID (e.g. 'subagent-1')" },
            message: { type: "string", description: "The message content to deliver" },
            steps: { type: "integer", description: "Optional additional step budget to grant alongside message" }
          },
          required: ["recipient", "message"]
        }
      )
      def initialize(supervisor: nil, runtime_context: nil)
        super(DECLARATION)
        @supervisor = supervisor
        @runtime_context = runtime_context
      end

      # Subagent-plane rebind (ScopedRegistry delegate): the subagent-plane
      # message must carry its REAL sender id to the maestro.
      def rebind_to(ctx)
        self.class.new(supervisor: resolve_supervisor(nil, ctx), runtime_context: ctx)
      end

      def execute(args = {})
        sup = resolve_supervisor(@supervisor, @runtime_context)
        return ToolOutput.error("SubagentSupervisor is not available in runtime context.") unless sup

        # Same model-output surface as manage_subagents: the recipient id
        # goes through the shared dialect normalizer (B5). A multi-id list
        # is an explicit error — a messaging tool must never silently drop
        # recipients.
        list = Rubik::Orchestrator::Subagent::ConversationId.normalize_list(args["recipient"] || args[:recipient])
        return ToolOutput.error("Missing required parameter 'recipient'.") if list.empty?
        if list.size > 1
          return ToolOutput.error(
            "send_message takes ONE recipient; got #{list.size} (#{list.join(', ')}). " \
            "Send one message per recipient, or use manage_subagents for roster actions."
          )
        end

        recipient = list.first
        msg = (args["message"] || args[:message]).to_s.strip
        return ToolOutput.error("Missing required parameter 'message'.") if msg.empty?

        steps = args["steps"] || args[:steps]
        sender = subagent_sender_id
        delivered = if sender
                      sup.send_message(recipient, msg, additional_steps: steps, _sender_id: sender)
                    else
                      sup.send_message(recipient, msg, additional_steps: steps)
                    end
        return delivery_text(recipient) if delivered == true
        return queued_text(recipient, steps) if delivered == :queued

        # A dependency-queued (or launching) spec exists but has never run:
        # "not found" is false, and the redeploy suggestion below would
        # refuse the same id — the model needs the truthful next action.
        if sup.respond_to?(:get) && (spec = sup.get(recipient)) && spec.respond_to?(:queued?) &&
           (spec.queued? || spec.spawning?)
          return ToolOutput.error(
            "Subagent '#{recipient}' is dependency-queued (deps: #{spec.depends_on.join(', ')}) and will " \
            "launch automatically when its predecessors settle. Messages cannot be buffered on an unborn " \
            "spec — re-send after it launches, or kill it with manage_subagents(action: 'kill', " \
            "conversation_id: '#{recipient}') if the wait is no longer worth it."
          )
        end

        ToolOutput.error(
          "Subagent '#{recipient}' not found or no longer active. If it recently finished, redeploy it with its " \
          "context intact: manage_subagents(action: 'redeploy', conversation_id: '#{recipient}', prompt: '<task>') " \
          "(if the runtime reports it is still settling, retry shortly); a fresh spawn is needed only after it was reaped."
        )
      end

      private

      # Subagent düzlemi (rebound araç): gönderen coeffect'i GERÇEK subagent
      # id'sidir. Kök düzleminde sağlanmaz → Supervisor default'u kalır.
      def subagent_sender_id
        service(:subagent_sender_id)
      end

      # Kök alias'ına giden mesajın yanıtı kök kişisiyle konuşur ("the
      # maestro supervisor"), alıcıyı "subagent" diye adlandırmaz.
      def delivery_text(recipient)
        root_alias = Rubik::Orchestrator::Subagent::ConversationId.root_alias?(recipient)
        return "Message successfully delivered to the maestro supervisor." if root_alias

        "Message successfully delivered to subagent '#{recipient}'."
      end

      # Bitmiş ama henüz reap edilmemiş alıcı: mesaj inbox'ta bekler,
      # redeploy history'ye boşaltır (Supervisor#send_message :queued).
      def queued_text(recipient, steps)
        note = if steps.to_i.positive?
                 " The requested #{steps}-step grant is NOT applied to a queued message — redeploy mints a fresh budget."
               else
                 ""
               end
        "Subagent '#{recipient}' has finished; message QUEUED in its inbox and will be delivered when it is " \
          "redeployed (manage_subagents action: 'redeploy', conversation_id: '#{recipient}'). It is lost if the " \
          "subagent is reaped first.#{note}"
      end
    end
  end
end
