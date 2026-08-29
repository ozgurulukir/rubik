# frozen_string_literal: true

require_relative "../prompt/context_compactor"

module Rubik
  module REPL
    # Plan 61: cross-turn conversational memory policy, included by Shell.
    # Covers sticky route resolution (D-7), per-turn outcome recording for
    # success/failure/cancel (D-2), and the token-budgeted conversation
    # window (D-12). All state lives on Shell; this module only encodes
    # the policy.
    module TurnRecorder
      MAX_CONVERSATION_ENTRIES = Rubik::Prompt::ContextCompactor::DEFAULT_MAX_CONVERSATION_ENTRIES

      # Plan 61 D-7: sticky routing. Once a conversation has started,
      # free-text turns keep the established provider/model instead of
      # re-running keyword classification every turn (mid-conversation
      # model/style/context-limit churn). `!model` resets the stamp via
      # sync_default_provider; explicit task types (!plan/!goal) never
      # touch it. Disable with `!config set router.sticky false`.
      def resolve_turn_route(text)
        sticky = @config.fetch("router.sticky", true) != false
        return @conversation_route_stamp if sticky && @conversation_route_stamp && !@conversation_history.empty?

        routed = @router.route(task_type: :auto, prompt: text)
        @conversation_route_stamp = routed if routed && routed[:provider]
        routed
      end

      # Plan 61 D-2: every free-text turn — success, failure, cancel —
      # leaves a user/assistant pair in the conversation window so the
      # model keeps the thread and !resume restores it. Failures record a
      # tagged trace plus the attempted-work summary so the next turn knows
      # what was already done.
      def record_turn_outcome!(user_text, assistant_content, tokens: nil, streamed: nil)
        return if user_text.to_s.strip.empty?
        return if assistant_content.nil? || assistant_content.to_s.strip.empty?

        @conversation_history << { role: "user", content: user_text }
        @conversation_history << { role: "assistant", content: assistant_content.to_s }
        trim_conversation_window!
        @recorder&.record_assistant_response(assistant_content.to_s, tokens: tokens, streamed: streamed)
      rescue StandardError
        nil
      end

      def record_failed_turn!(user_text, kind, reason, orchestrator)
        return if @config.fetch("context.log_failed_turns", true) == false

        label = case kind
                when "cancelled" then "[Turn cancelled by user (^C)]"
                when "incomplete" then "[Turn incomplete: #{reason}]"
                else "[Turn failed: #{reason}]"
                end
        summary = if orchestrator.respond_to?(:activity)
                    orchestrator.activity.summary(orchestrator.buffer_manager).to_s.strip
                  else
                    ""
                  end
        body = summary.empty? ? label : "#{label}\nPartial progress before this outcome:\n#{summary}"
        record_turn_outcome!(user_text, body)
      rescue StandardError
        nil
      end

      # Plan 61 D-12: the long-lived REPL memory is trimmed by a token
      # budget (plus an absolute entry cap) so one huge turn cannot evict
      # the whole thread, and eviction order stays oldest-first.
      def trim_conversation_window!
        ceiling = begin
          spec = current_model_spec
          @llm_registry.effective_input_limit_for(spec["provider"], spec["name"])
        rescue StandardError
          nil
        end
        @conversation_history = Rubik::Prompt::ContextCompactor.trim_history_to_budget(
          @conversation_history, ceiling: ceiling, max_entries: MAX_CONVERSATION_ENTRIES
        )
      rescue StandardError
        nil
      end

      # Plan 61 D-13: the model spec the CURRENT conversation is bound to
      # (sticky stamp when present), falling back to the default role.
      def current_model_spec
        stamp = @conversation_route_stamp
        return stamp[:spec] if stamp.is_a?(Hash) && stamp[:spec].is_a?(Hash) && stamp[:spec]["provider"]

        @config.model_spec(:default)
      end

      # Session continuity (Plan 34/61): hydrate a recorded session into
      # the live conversation window.
      def resume_session(identifier = :latest)
        root_d = @buffer_manager&.root_dir || Dir.pwd
        home_d = @config&.instance_variable_get(:@home_dir) || ENV.fetch("HOME", nil)

        target_file = if identifier == :latest || identifier.to_s.downcase == "latest"
                        Rubik::Session::Manager.find_latest_session(root_d, home_d, exclude_file: @recorder&.session_file)
                      else
                        Rubik::Session::Manager.find_session(identifier, root_d, home_d)
                      end

        return { ok: false, error: "No past session found matching '#{identifier}'" } unless target_file

        res = Rubik::Session::Manager.restore_session(self, target_file)
        if res[:ok]
          @output.puts "[Rubik::Session] Resumed session: #{File.basename(target_file)} (#{res[:turns_hydrated]} dialogue turns hydrated, 0 API tokens used)"
        end
        res
      end
    end
  end
end
