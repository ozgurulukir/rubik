# frozen_string_literal: true

require_relative "context_compactor"
require_relative "../tools/truncator"

module Rubik
  module Prompt
    # Mutating context compactor for hot paths. Where ContextCompactor
    # is pure (returns a new history), EmergencyCompactor mutates the
    # given history in place for callers that need a fast reduction
    # without an extra allocation.
    #
    # Use ContextCompactor first; fall back to EmergencyCompactor
    # only when a quick reduction is needed and the caller accepts
    # the in-place mutation.
    module EmergencyCompactor
      module_function

      # Plan 63 Faz A: tiered escalation. When the caller supplies a positive
      # context_limit, the structural ContextCompactor (tool-result pruning,
      # atomic-unit sliding window with a summary marker) runs first with
      # force: true; the blind 300/1000-char truncation is the last resort,
      # applied only when the history is still over budget afterwards.
      # Without a context_limit the behavior is identical to the legacy
      # single-layer path, so direct callers keep their exact contract.
      #
      # The history Array keeps its identity (in-place replace), so callers
      # holding a reference — StreamManager retry, session recorders — see
      # the compacted messages. Returns the layer that produced the final
      # history (:structural or :hard_truncate); the nil/empty guards return
      # the input unchanged (pinned by tests). No production caller consumes
      # the return value; it feeds the :emergency_compact on_step event.
      def compact!(history, context_limit: nil, max_output_tokens: nil, config: {})
        return history if history.nil? || history.empty?

        max_out = max_output_tokens || 4096
        if context_limit&.positive?
          structural = Rubik::Prompt::ContextCompactor.compact_history(
            history, context_limit: context_limit,
                     max_output_tokens: max_out, config: config, force: true
          )
          history.replace(structural)
          still_over = Rubik::Prompt::ContextCompactor.needs_compaction?(
            history, context_limit: context_limit, max_output_tokens: max_out, config: config
          )
          return :structural unless still_over
        end

        history.each do |msg|
          next unless msg.is_a?(Hash)

          role = (msg[:role] || msg["role"]).to_s
          content_key = msg.key?(:content) ? :content : "content"
          content = msg[content_key].to_s

          if ["tool", "tool_result"].include?(role)
            if content.length > 300
              trunc = Rubik::Tools::Truncator.truncate(content, max_chars: 300, max_lines: 10, strategy: :head_tail)
              msg[content_key] = trunc[:text]
            end
          elsif role == "assistant" && content.length > 1000
            trunc = Rubik::Tools::Truncator.truncate(content, max_chars: 1000, max_lines: 30, strategy: :head_tail)
            msg[content_key] = trunc[:text]
          end
        end

        :hard_truncate
      end
    end
  end
end
