# frozen_string_literal: true

require_relative "../prompt"

module Rubik
  module Orchestrator
    # Step-budget warnings, token accounting and context-compaction decisions
    # (Plan 54 D-6). Stateless collaborator over Loop-held state: counters are
    # read through accessors at call time (tests may poke them between calls)
    # and the total_tokens hash is mutated in place so Loop's reader keeps its
    # object identity.
    class BudgetManager
      def initialize(loop)
        @loop = loop
      end

      def evaluate_step_budget_warning!(warn_step, warned)
        return warned if warned || @loop.step_count < warn_step || @loop.step_count >= @loop.max_steps

        remaining = @loop.max_steps - @loop.step_count
        warning_xml = "\n\n<step_budget current=\"#{@loop.step_count}\" max=\"#{@loop.max_steps}\" remaining=\"#{remaining}\" " \
                      "alert=\"Step budget nearing limit (#{remaining} steps left). Please begin concluding your work, " \
                      "verify with tests/diagnostics, and call finish.\" />"
        if @loop.history.last && @loop.history.last.is_a?(Hash)
          @loop.history.last[:content] = "#{@loop.history.last[:content]}#{warning_xml}"
        else
          @loop.history << { role: "user", content: warning_xml.strip }
        end
        @loop.on_step&.call(type: :step_warning, current: @loop.step_count, max: @loop.max_steps, remaining: remaining)
        true
      end

      def evaluate_context_compaction!
        return unless @loop.context_limit

        context_cfg = @loop.config ? @loop.config.fetch("context", {}) : {}
        needs = Rubik::Prompt::ContextCompactor.needs_compaction?(
          @loop.history, context_limit: @loop.context_limit,
          max_output_tokens: @loop.max_output_tokens, config: context_cfg
        )
        return unless needs

        # compact_history is pure and returns a new array, so the history
        # reference itself must be rebound on Loop.
        @loop.history = Rubik::Prompt::ContextCompactor.compact_history(
          @loop.history, context_limit: @loop.context_limit,
          max_output_tokens: @loop.max_output_tokens, config: context_cfg
        )
      end

      def track_token_usage!(res)
        return unless res.respond_to?(:usage) && res.usage

        @loop.total_tokens[:input] += res.usage[:input_tokens] || res.usage["input_tokens"] || 0
        @loop.total_tokens[:output] += res.usage[:output_tokens] || res.usage["output_tokens"] || 0
      end

      def estimate_tokens_from_history
        total_text = @loop.history.map { |m| m[:content] || m["content"] }.compact.join
        @loop.provider.respond_to?(:estimate_tokens) ? @loop.provider.estimate_tokens(total_text) : (total_text.length / 4.0).ceil
      end
    end
  end
end
