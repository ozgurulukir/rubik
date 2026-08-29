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

      def compact!(history)
        return history if history.nil? || history.empty?

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

        history
      end
    end
  end
end
