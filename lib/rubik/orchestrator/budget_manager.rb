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
        # Plan 61 D-14: send as its own user message — concatenating onto
        # @history.last can weld the XML onto a tool result or a
        # content-less assistant message, which provider formatters mangle.
        warning_xml = "<step_budget current=\"#{@loop.step_count}\" max=\"#{@loop.max_steps}\" remaining=\"#{remaining}\" " \
                      "alert=\"Step budget nearing limit (#{remaining} steps left). Please begin concluding your work, " \
                      "verify with tests/diagnostics, and call finish.\" />"
        @loop.history << { role: "user", content: warning_xml }
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

        in_tokens = res.usage[:input_tokens] || res.usage["input_tokens"] || 0
        @loop.total_tokens[:input] += in_tokens
        @loop.total_tokens[:output] += res.usage[:output_tokens] || res.usage["output_tokens"] || 0
        warn_context_truncation!(in_tokens)
      end

      # Plan 61 D-1: usage input_tokens is the server's ground truth. When
      # it approaches the configured window the provider (not the compactor)
      # is clipping the prompt head — surface it once so silent context loss
      # becomes visible instead of reading as "the model forgot everything".
      def warn_context_truncation!(in_tokens)
        return if @loop.context_limit.nil? || in_tokens.to_i <= 0
        return if in_tokens.to_i < (@loop.context_limit * 0.9)
        return if @loop.context_warning_emitted

        @loop.context_warning_emitted = true
        @loop.on_step&.call(
          type: :context_truncation_warning,
          input_tokens: in_tokens.to_i,
          context_limit: @loop.context_limit,
          step: @loop.step_count,
          max_steps: @loop.max_steps
        )
      end

      def estimate_tokens_from_history
        # Use the same estimator as the compaction math (Plan 61 D-1): the
        # usage fallback must agree with the window the request was sized for.
        Rubik::Prompt::TokenEstimator.estimate_history(@loop.history)
      end
    end
  end
end
