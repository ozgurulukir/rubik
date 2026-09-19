# frozen_string_literal: true

require_relative "../platform"

module Rubik
  module Runtime
    class ExecutionFailure
      attr_reader :cmd, :exit_code, :stdout, :stderr, :duration, :category, :suggestion, :metadata, :timestamp

      def initialize(cmd:, exit_code:, stdout: "", stderr: "", duration: 0.0, category: :unknown_failure, suggestion: nil, metadata: {})
        @cmd = cmd.to_s
        @exit_code = exit_code.to_i
        @stdout = stdout.to_s
        @stderr = stderr.to_s
        @duration = duration.to_f
        @category = category.to_sym
        @suggestion = suggestion.to_s
        @metadata = metadata || {}
        @timestamp = begin
          Time.now.utc.iso8601
        rescue
          Time.now.to_s
        end
      end

      def to_h
        {
          cmd: @cmd,
          exit_code: @exit_code,
          stdout: @stdout,
          stderr: @stderr,
          duration: @duration,
          category: @category,
          suggestion: @suggestion,
          metadata: @metadata,
          timestamp: @timestamp
        }
      end

      def format_for_llm
        lines = [
          "=== Runtime Execution Diagnostic ===",
          "• Command     : #{@cmd}",
          "• Exit Code   : #{@exit_code}",
          "• Duration    : #{@duration.round(4)}s",
          "• Category    : #{@category.to_s.upcase}"
        ]
        lines << "• Stderr      : #{@stderr.strip}" unless @stderr.strip.empty?
        lines << "• Stdout      : #{@stdout.strip}" if @stderr.strip.empty? && !@stdout.strip.empty?
        lines << "• Suggestion  : #{@suggestion}" unless @suggestion.strip.empty?
        lines.join("\n")
      end
    end

    module DiagnosticEngine
      class << self
        def diagnose(cmd:, exit_code:, stdout: "", stderr: "", duration: 0.0, metadata: {})
          cmd_str = cmd.to_s
          stderr_str = stderr.to_s
          stdout_str = stdout.to_s
          combined = "#{stderr_str}\n#{stdout_str}"

          category = determine_category(cmd_str, exit_code, stderr_str, stdout_str, combined)
          suggestion = generate_suggestion(category, cmd_str, combined)

          ExecutionFailure.new(
            cmd: cmd_str,
            exit_code: exit_code,
            stdout: stdout_str,
            stderr: stderr_str,
            duration: duration,
            category: category,
            suggestion: suggestion,
            metadata: metadata
          )
        end

        def analyze_process_result(process_result, cmd: nil, metadata: {})
          return nil if process_result.nil?

          res_cmd = cmd || process_result[:cmd] || "unknown_command"
          diagnose(
            cmd: res_cmd,
            exit_code: process_result[:exit_code] || (process_result[:ok] ? 0 : 1),
            stdout: process_result[:stdout] || "",
            stderr: process_result[:stderr] || (process_result[:ok] ? "" : process_result[:output].to_s),
            duration: process_result[:duration] || 0.0,
            metadata: metadata
          )
        end

        private

        def determine_category(_cmd, exit_code, _stderr, _stdout, combined)
          return :success if exit_code.zero?

          if exit_code == 124 || combined.match?(/(timed out|timeout after|\btimeout\b)/i)
            :timeout
          elsif exit_code == 127 || exit_code == 9009 || exit_code == 49 ||
                combined.match?(/(not recognized|\bnot found\b|command not found|cannot find|bulunamad|\bENOENT\b)/i)
            :missing_binary
          elsif combined.match?(/(permission denied|\bEACCES\b|operation not permitted)/i)
            :permission_denied
          elsif combined.match?(/(unrecognized option|unknown option|invalid option|requires stdio|--stdio|flag provided but not defined|unknown flag)/i)
            :missing_flag_or_option
          elsif combined.match?(
            /(cannot load such file|ModuleNotFoundError|No module named|package .* not found|bundle install|npm install|pnpm install|yarn install)/i
          )
            :dependency_missing
          elsif combined.match?(/(syntax error|unexpected token|compilation error|error\[E\d+\]|parse error|fatal error)/i)
            :syntax_or_compile_error
          elsif combined.match?(/(failures:|assertions|tests failed|failed tests|FAILED \(|FAIL:|\d+ failures, \d+ errors)/i)
            :test_failure
          else
            :unknown_failure
          end
        end

        def generate_suggestion(category, cmd, _combined)
          bin = cmd.split.first || "command"

          case category
          when :missing_binary
            "The executable binary '#{bin}' was not found in PATH or root workspace. " \
            "Install the required tool or use `repair_runtime_service` / `!synthesize` to configure a working alternative."
          when :missing_flag_or_option
            "Command line flags or arguments appear invalid. Check supported flags (e.g. `--stdio`, `stdio`) " \
            "or use `repair_runtime_service` to probe correct options."
          when :dependency_missing
            "Required dependencies are missing. Run appropriate package manager install " \
            "(e.g., `bundle install`, `npm install`, `pip install`) before proceeding."
          when :syntax_or_compile_error
            "A syntax or compilation error occurred. Inspect the reported source file and line numbers to resolve the error."
          when :permission_denied
            "Permission denied for '#{bin}'. Check file permissions (chmod +x) or sandbox security constraints."
          when :timeout
            "Process execution exceeded timeout threshold. Increase timeout limit or investigate potential infinite loops / blocking calls."
          when :test_failure
            "One or more tests failed. Review assertion failure outputs and update the corresponding implementation."
          when :success
            "Command executed successfully."
          else
            "Process exited with non-zero code. Review stderr/stdout traces to investigate cause."
          end
        end
      end
    end
  end
end
