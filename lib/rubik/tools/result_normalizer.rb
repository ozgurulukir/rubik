# frozen_string_literal: true

require_relative "truncator"
require_relative "result"

module Rubik
  module Tools
    # Single home for tool-output carrier normalization: every tool outcome —
    # Result-backed, status-bearing duck object, or plain string — is
    # normalized into the Result contract here, and both orchestrator planes
    # (StepExecutor root, Subagent ToolDispatch) delegate to this one
    # implementation instead of maintaining parallel copies.
    #
    # Plane differences are caller-supplied parameters, not divergent logic:
    # the root plane passes its measured wall time and the tool-call id; the
    # subagent plane leaves both nil.
    module ResultNormalizer
      # Carrier strings whose first-line presence marks an otherwise opaque
      # string result as an error. Shared lexicon; referenced by tests via
      # StepExecutor::ERROR_PREFIXES (kept as an alias there).
      ERROR_PREFIXES = [
        "-- ", "Error:", "Error ", "Usage:", "Pre-flight verification failed",
        "Bilinmeyen komut", "Failed", "Security blocked", "Command error",
        "[EXIT ", "Test run [FAILED]", "Lint [FAILED]", "[CONFLICT]", "[CONFLICT "
      ].freeze

      # Truncation knob trio (chars, lines, strategy) from a config object;
      # nil / non-fetchable configs fall back to Truncator defaults. A
      # non-nil config that cannot fetch warns once before falling back —
      # operator-set limits must never be dropped in silence.
      def self.limits(config)
        cfg = config.respond_to?(:fetch) ? config : nil
        warn_once(config.class) if cfg.nil? && !config.nil?
        max_chars = cfg&.fetch("tools.max_output_chars", Truncator::DEFAULT_MAX_CHARS) || Truncator::DEFAULT_MAX_CHARS
        max_lines = cfg&.fetch("tools.max_output_lines", Truncator::DEFAULT_MAX_LINES) || Truncator::DEFAULT_MAX_LINES
        strategy = Truncator.resolve_strategy(cfg&.fetch("tools.truncation_strategy", Truncator::DEFAULT_STRATEGY))
        [max_chars, max_lines, strategy]
      end

      # One warning per process per config class; a warn per tool result
      # would be exactly the stderr storm the truncation warn doctrine bans.
      def self.warn_once(klass)
        @warned ||= {}
        return if @warned[klass]

        @warned[klass] = true
        Rubik::Log.warn(:tools, "tools truncation knobs skipped: config object of class #{klass} does not respond to fetch; using Truncator defaults")
      end

      # duration_ms: caller-measured wall time (nil on the subagent plane).
      # call_id: caller's tool-call id (nil on the subagent plane).
      def self.normalize(raw, tool_name:, call_id: nil, duration_ms: nil, config: nil)
        max_chars, max_lines, strategy = limits(config)

        if raw.is_a?(Result)
          trunc = Truncator.truncate(raw.output, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
          # Truncation only shortens the display text — status, exit code,
          # metadata and the original truncation flag all survive it.
          effective_dur = raw.duration_ms.positive? ? raw.duration_ms : duration_ms.to_f
          first_line = first_line_of(raw.output)
          Result.new(
            tool_name: raw.tool_name.to_s.empty? ? tool_name : raw.tool_name,
            call_id: raw.call_id.to_s.empty? ? call_id : raw.call_id,
            status: raw.status, error: raw.error || (raw.error? ? first_line : nil),
            # Structured fields ride along when the tool provides them
            # (issue #127): the same Result contract for every carrier.
            exit_code: raw.exit_code, output: trunc[:text], duration_ms: effective_dur,
            truncated: raw.truncated || trunc[:truncated], metadata: raw.metadata
          )
        elsif raw.respond_to?(:status) && raw.respond_to?(:output)
          out_str = raw.output.to_s
          trunc = Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
          status = raw.status.to_sym
          first_line = first_line_of(out_str)
          err = (raw.respond_to?(:error) && raw.error) || (status == :error ? first_line : nil)
          Result.new(
            tool_name: tool_name, call_id: call_id, status: status, error: err, output: trunc[:text],
            duration_ms: duration_ms.to_f, truncated: trunc[:truncated],
            exit_code: raw.respond_to?(:exit_code) ? raw.exit_code : nil,
            metadata: raw.respond_to?(:metadata) ? raw.metadata : {}
          )
        else
          out_str = raw.to_s
          trunc = Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: strategy)
          # elsif chain (not two independent checks): a carrier answering
          # error? takes that verdict even when failed? would disagree —
          # root-plane precedence, pinned by the hardening tests.
          is_err = if raw.respond_to?(:error?)
                     raw.error?
                   elsif raw.respond_to?(:failed?)
                     raw.failed?
                   elsif raw.is_a?(String)
                     ERROR_PREFIXES.any? { |pfx| out_str.start_with?(pfx) }
                   else
                     false
                   end

          first_line = first_line_of(out_str)
          Result.new(
            tool_name: tool_name, call_id: call_id, status: is_err ? :error : :ok,
            error: is_err ? first_line : nil, output: trunc[:text],
            duration_ms: duration_ms.to_f, truncated: trunc[:truncated]
          )
        end
      end

      # A blank first line carries no diagnostic value: nil it so error
      # fields never hold "" (pinned by the empty-output hardening test).
      def self.first_line_of(text)
        line = text.lines.first.to_s.strip
        line.empty? ? nil : line
      end
    end
  end
end
