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
          max_chars = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_chars", 12_000) : 12_000) || 12_000
          max_lines = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_lines", 300) : 300) || 300
          normalize_tool_result(raw, name, max_chars: max_chars.to_i, max_lines: max_lines.to_i)
        rescue StandardError => e
          error_result(name, "Tool execution error: #{e.class}: #{e.message}", error: e.message)
        end

        private

        def normalize_tool_result(raw, name, max_chars:, max_lines:)
          if raw.is_a?(Rubik::Tools::Result)
            trunc = Rubik::Tools::Truncator.truncate(raw.output, max_chars: max_chars, max_lines: max_lines)
            # Truncation only shortens the display text — status, exit code,
            # metadata and the original truncation flag all survive it.
            Rubik::Tools::Result.new(tool_name: raw.tool_name.to_s.empty? ? name : raw.tool_name,
                                     status: raw.status, error: raw.error, exit_code: raw.exit_code,
                                     output: trunc[:text], duration_ms: raw.duration_ms,
                                     truncated: raw.truncated || trunc[:truncated], metadata: raw.metadata)
          elsif raw.respond_to?(:status) && raw.respond_to?(:output)
            out_str = raw.output.to_s
            trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines)
            Rubik::Tools::Result.new(tool_name: name, status: raw.status.to_sym, output: trunc[:text],
                                     truncated: trunc[:truncated],
                                     exit_code: raw.respond_to?(:exit_code) ? raw.exit_code : nil,
                                     metadata: raw.respond_to?(:metadata) ? raw.metadata : {})
          else
            out_str = raw.to_s
            trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines)
            status = raw.respond_to?(:error?) && raw.error? ? :error : :ok
            Rubik::Tools::Result.new(tool_name: name, status: status,
                                     error: status == :error ? out_str.lines.first.to_s.strip : nil,
                                     output: trunc[:text], truncated: trunc[:truncated])
          end
        end

        def error_result(name, text, error: nil)
          Rubik::Tools::Result.new(tool_name: name, status: :error, output: text, error: error || text)
        end
      end
    end
  end
end
