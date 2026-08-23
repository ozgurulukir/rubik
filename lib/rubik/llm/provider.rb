# frozen_string_literal: true

module Rubik
  module LLM
    class Response
      attr_reader :text, :usage, :raw

      def initialize(text:, usage: {}, raw: {})
        @text = text
        @usage = usage # { input_tokens: int, output_tokens: int }
        @raw = raw
      end
    end

    class BaseProvider
      def complete(messages, opts = {})
        raise NotImplementedError, "#{self.class} must implement #complete"
      end

      def sanitize_prompt(prompt)
        "<user_input>#{prompt}</user_input>"
      end

      def estimate_tokens(text)
        return 0 if text.nil? || text.empty?
        (text.to_s.length / 4.0).ceil
      end
    end
  end
end
