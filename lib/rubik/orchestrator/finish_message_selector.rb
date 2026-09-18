# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Selects the final message shown to the user when the agent finishes.
    # Extracted from StepExecutor#handle_finish_tool (review Finding 5): the
    # heuristic was inline, undocumented, and its magic substring
    # `!clean_text_resp.include?("tool")` had no explanation of intent.
    #
    # Inputs (both already normalized by the caller):
    #   narration — the turn's free text with JSON tool-call blocks stripped
    #               (StepExecutor#clean_llm_text), stripped and possibly empty.
    #   tool_msg  — the finish tool's `message` argument, stripped.
    #
    # Selection (behavior preserved exactly from the inline version):
    #   1. tool_msg non-empty and NOT a generic filler ("completed", "done",
    #      "finished", "ok", "task_completed"):
    #        - narration and message don't subsume each other -> both, joined.
    #        - otherwise keep the richer (longer) one, unless the narration is
    #          mere tool-usage narration (see NARRATION_TOOL_HINT below).
    #   2. tool_msg empty or generic filler: prefer the narration if present.
    #   3. Neither has content: fallback constant.
    #
    # The narration-skip heuristic: a narration that merely mentions "tool"
    # ("I'll use the run_tests tool next...") is process talk, not an answer;
    # the finish tool's message is the better user-facing summary, so the
    # message wins even when the narration is longer.
    module FinishMessageSelector
      GENERIC_FILLERS = ["completed", "done", "finished", "ok", "task_completed"].freeze
      NARRATION_TOOL_HINT = "tool"
      DEFAULT_MESSAGE = "Completed"

      module_function

      def select(narration, tool_msg)
        narration = narration.to_s
        tool_msg = tool_msg.to_s

        if !tool_msg.empty? && !GENERIC_FILLERS.include?(tool_msg.downcase)
          if !narration.empty? && !narration.include?(tool_msg) && !tool_msg.include?(narration)
            "#{narration}\n\n#{tool_msg}"
          elsif narration.length > tool_msg.length && !narration.include?(NARRATION_TOOL_HINT)
            narration
          else
            tool_msg
          end
        elsif !narration.empty?
          narration
        else
          tool_msg.empty? ? DEFAULT_MESSAGE : tool_msg
        end
      end
    end
  end
end
