# frozen_string_literal: true

require_relative "../../tools/result_normalizer"
require_relative "../tool_timeout"

module Rubik
  module Orchestrator
    module Subagent
      # Subagent-plane tool dispatch (issue #127), extracted from StepRunner:
      # every outcome — Result-backed, status-bearing, plain string, missing
      # tool, or raised error — is normalized into the Result contract so
      # status / exit_code / metadata survive truncation and reach the
      # canonical history row. Classification itself lives in
      # Tools::ResultNormalizer, shared verbatim with the root StepExecutor,
      # so the two channels cannot drift.
      module ToolDispatch
        def dispatch_subagent_tool(tool, name, args)
          return error_result(name, "Tool '#{name}' is not available in subagent toolset.") unless tool

          cfg = @config.respond_to?(:fetch) ? @config : nil
          raw = Rubik::Orchestrator::ToolTimeout.call(tool, config: cfg,
                                                            canonical_name: tool.respond_to?(:name) ? tool.name : name) do
            tool.execute(args)
          end
          normalize_tool_result(raw, name)
        rescue Rubik::Orchestrator::ToolTimeout::BudgetExceeded => e
          Rubik::Orchestrator::ToolTimeout.emit_timeout_event(tool_name: name, budget_seconds: e.budget_seconds,
                                                              elapsed_seconds: e.elapsed_seconds, context: @context)
          Rubik::Orchestrator::ToolTimeout.timeout_result(tool_name: name, call_id: nil, exceeded: e,
                                                          duration_ms: (e.elapsed_seconds * 1000).round(1))
        rescue StandardError => e
          error_result(name, "Tool execution error: #{e.class}: #{e.message}", error: e.message)
        end

        private

        # Thin delegator: carrier classification and truncation limits live
        # in Tools::ResultNormalizer — the single home both orchestrator
        # planes share, so the channels cannot drift. The
        # subagent plane passes no call_id/duration_ms (nothing measured
        # here); wrapping stays local so a normalize bug is contained into an
        # error result by dispatch_subagent_tool's rescue.
        def normalize_tool_result(raw, name)
          Rubik::Tools::ResultNormalizer.normalize(raw, tool_name: name, config: @config)
        end

        def error_result(name, text, error: nil)
          Rubik::Tools::Result.new(tool_name: name, status: :error, output: text, error: error || text)
        end
      end
    end
  end
end
