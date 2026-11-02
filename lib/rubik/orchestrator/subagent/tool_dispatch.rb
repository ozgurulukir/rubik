# frozen_string_literal: true

require_relative "../../tools/truncator"
require_relative "../../tools/result"

module Rubik
  module Orchestrator
    module Subagent
      # Subagent-plane tool dispatch (issue #127), extracted from StepRunner:
      # every outcome — Result-backed, status-bearing, plain string, missing
      # tool, or raised error — is normalized into the Result contract so
      # status / exit_code / metadata survive truncation and reach the
      # canonical history row. Same classification as the root StepExecutor,
      # so the two channels cannot drift.
      module ToolDispatch
        def dispatch_subagent_tool(tool, name, args)
          return error_result(name, "Tool '#{name}' is not available in subagent toolset.") unless tool

          raw = tool.execute(args)
          cfg = @config.respond_to?(:fetch) ? @config : nil
          max_chars = (cfg&.fetch("tools.max_output_chars", Rubik::Tools::Truncator::DEFAULT_MAX_CHARS) || Rubik::Tools::Truncator::DEFAULT_MAX_CHARS).to_i
          max_lines = (cfg&.fetch("tools.max_output_lines", Rubik::Tools::Truncator::DEFAULT_MAX_LINES) || Rubik::Tools::Truncator::DEFAULT_MAX_LINES).to_i
          strategy = Rubik::Tools::Truncator.resolve_strategy(cfg&.fetch("tools.truncation_strategy", Rubik::Tools::Truncator::DEFAULT_STRATEGY))
          normalize_tool_result(raw, name, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
        rescue StandardError => e
          error_result(name, "Tool execution error: #{e.class}: #{e.message}", error: e.message)
        end

        private

        def normalize_tool_result(raw, name, max_chars:, max_lines:, strategy: Rubik::Tools::Truncator::DEFAULT_STRATEGY)
          if raw.is_a?(Rubik::Tools::Result)
            trunc = Rubik::Tools::Truncator.truncate(raw.output, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
            # Truncation only shortens the display text — status, exit code,
            # metadata and the original truncation flag all survive it.
            first_line = raw.output.to_s.lines.first.to_s.strip
            Rubik::Tools::Result.new(tool_name: raw.tool_name.to_s.empty? ? name : raw.tool_name,
                                     status: raw.status,
                                     error: raw.error || (raw.error? ? first_line : nil), exit_code: raw.exit_code,
                                     output: trunc[:text], duration_ms: raw.duration_ms,
                                     truncated: raw.truncated || trunc[:truncated], metadata: raw.metadata)
          elsif raw.respond_to?(:status) && raw.respond_to?(:output)
            out_str = raw.output.to_s
            trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
            first_line = out_str.lines.first.to_s.strip
            status = raw.status.to_sym
            Rubik::Tools::Result.new(tool_name: name, status: status,
                                     error: (raw.respond_to?(:error) && raw.error) || (status == :error ? first_line : nil),
                                     output: trunc[:text], truncated: trunc[:truncated],
                                     exit_code: raw.respond_to?(:exit_code) ? raw.exit_code : nil,
                                     metadata: raw.respond_to?(:metadata) ? raw.metadata : {})
          else
            out_str = raw.to_s
            trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
            status = classify_raw_string(raw, out_str)
            Rubik::Tools::Result.new(tool_name: name, status: status,
                                     error: status == :error ? out_str.lines.first.to_s.strip : nil,
                                     output: trunc[:text], truncated: trunc[:truncated])
          end
        end

        # Root-parity string classification (arch scan card 5, review F1): the
        # same lexicon as StepExecutor#normalize_raw_output's else branch —
        # error?/failed? predicates, then the shared ERROR_PREFIXES table.
        # Without this, a bare "Error: ..." string reads status=ok in subagent
        # history while the root plane honestly reports :error.
        def classify_raw_string(raw, out_str)
          return :error if raw.respond_to?(:error?) && raw.error?
          return :error if raw.respond_to?(:failed?) && raw.failed?
          return :error if raw.is_a?(String) && Rubik::Orchestrator::StepExecutor::ERROR_PREFIXES.any? { |pfx| out_str.start_with?(pfx) }

          :ok
        end

        def error_result(name, text, error: nil)
          Rubik::Tools::Result.new(tool_name: name, status: :error, output: text, error: error || text)
        end
      end
    end
  end
end
