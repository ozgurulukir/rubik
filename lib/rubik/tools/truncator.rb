# frozen_string_literal: true

module Rubik
  module Tools
    module Truncator
      DEFAULT_MAX_CHARS = 12_000
      DEFAULT_MAX_LINES = 300
      # The strategy knob's default lives here (arch scan card 5, 2026-11-01):
      # both orchestrator planes read tools.truncation_strategy with this
      # fallback — one literal for the whole repo instead of restated copies.
      DEFAULT_STRATEGY = :head_tail
      # Known-strategy set (issue #349): a typo'd config value used to die
      # silently into the head_tail `else` branch in both planes. This set
      # is the honest frontier — resolve_strategy warns against it, and a
      # new strategy added to #truncate must register here to be reachable.
      STRATEGIES = [:head_tail, :head_only, :tail_only].freeze

      class << self
        # Configured-value resolver for the strategy fetch sites (root
        # StepExecutor + subagent ToolDispatch + prompt EmergencyCompactor).
        # nil/false/empty/missing fall back to the default SILENTLY (that
        # path is correct today); a non-empty value outside STRATEGIES warns
        # ONCE per distinct knob+value pair, then keeps the default — the
        # operator "tuning" truncation with a typo must not get
        # byte-identical old behavior in silence. `key:` names the config
        # knob in the warn so each caller's message points at its own
        # setting, and the frontier dedups on the pair: the same typo under
        # two different knobs must warn twice, or fixing one knob leaves
        # the other misconfigured in silence.
        def resolve_strategy(value, key: "tools.truncation_strategy")
          return DEFAULT_STRATEGY if value.nil? || value == false || value.to_s.strip.empty?

          sym = value.to_s.downcase.to_sym
          return sym if STRATEGIES.include?(sym)

          warn_unknown_strategy(value, key)
          DEFAULT_STRATEGY
        end

        private

        # One-time-per-knob-and-value warn (UI::Theme#paint precedent):
        # the first bad value speaks, re-occurrences (every tool result
        # would re-resolve) stay quiet. Warn level, not debug: a config
        # typo is operator-visible in normal operation. The value is
        # forced to UTF-8 and scrubbed BEFORE interpolation — scrub alone
        # is a no-op on BINARY strings — because Log.warn's rescue cannot
        # reach a message that fails to build, and a binary-encoding
        # config value must never turn tool results into errors.
        def warn_unknown_strategy(value, key)
          shown = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
          return unless unknown_strategies.add?([key, shown])

          Rubik::Log.warn(:tools, "#{key}='#{shown}' is not a known strategy (#{STRATEGIES.join('/')}) — using #{DEFAULT_STRATEGY}")
        end

        def unknown_strategies
          @unknown_strategies ||= Set.new
        end
      end

      def self.truncate(text, max_chars: DEFAULT_MAX_CHARS, max_lines: DEFAULT_MAX_LINES, strategy: :head_tail, separator: "\n")
        str = text.to_s
        # byteslice truncation below cuts on byte boundaries and can split a
        # multibyte character, producing invalid UTF-8 that then poisons the
        # whole downstream pipeline (JSON generation, regex work, token
        # estimation). Scrub exactly once, after the last byteslice.
        str = str.scrub("") unless str.valid_encoding?

        max_c = [(max_chars || DEFAULT_MAX_CHARS).to_i, 0].max
        max_l = [(max_lines || DEFAULT_MAX_LINES).to_i, 0].max
        sep = separator || "\n"

        # PERF: With the default newline separator, calculate the line upper bound
        # using zero-allocation C-level #count("\n") and short-circuit BEFORE
        # calling #lines (which allocates an Array of line strings).
        if sep == "\n"
          line_bound = if str.empty?
                         0
                       elsif str.end_with?("\n")
                         str.count("\n")
                       else
                         str.count("\n") + 1
                       end
          return { text: str, truncated: false, omitted_lines: 0, omitted_chars: 0 } if str.bytesize <= max_c && line_bound <= max_l
        end

        lines = str.lines(sep)
        return { text: str, truncated: false, omitted_lines: 0, omitted_chars: 0 } if str.bytesize <= max_c && lines.size <= max_l

        strategy_sym = strategy.to_s.downcase.to_sym

        case strategy_sym
        when :head_only
          kept_lines = lines.first(max_l)
          kept_str = kept_lines.join
          if kept_str.bytesize > max_c
            kept_str = kept_str.byteslice(0, max_c)
            kept_str = kept_str.scrub("") unless kept_str.valid_encoding?
          end
          kept_line_count = kept_str.empty? ? 0 : kept_str.lines(sep).size
          omitted_lines = [lines.size - kept_line_count, 0].max
          omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
          notice = "\n... [Truncated: omitted #{omitted_lines} lines / #{omitted_chars} chars] ...\n"
          { text: finalize(kept_str, notice, prefix: true), truncated: true,
            omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        when :tail_only
          kept_lines = lines.last(max_l)
          kept_str = kept_lines.join
          if kept_str.bytesize > max_c
            kept_str = kept_str.byteslice(-max_c, max_c)
            kept_str = kept_str.scrub("") unless kept_str.valid_encoding?
          end
          kept_line_count = kept_str.empty? ? 0 : kept_str.lines(sep).size
          omitted_lines = [lines.size - kept_line_count, 0].max
          omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
          notice = "\n... [Truncated: omitted #{omitted_lines} lines / #{omitted_chars} chars] ...\n"
          { text: finalize(kept_str, notice, prefix: false), truncated: true,
            omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        else # :head_tail
          if max_l <= 1
            kept_lines = lines.first(max_l)
            kept_str = kept_lines.join
            if kept_str.bytesize > max_c
              kept_str = kept_str.byteslice(0, max_c)
              kept_str = kept_str.scrub("") unless kept_str.valid_encoding?
            end
            kept_line_count = kept_str.empty? ? 0 : kept_str.lines(sep).size
            omitted_lines = [lines.size - kept_line_count, 0].max
            omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
            notice = "\n\n... [Truncated: #{omitted_lines} lines / #{omitted_chars} chars omitted to preserve token budget] ...\n\n"
            return { text: finalize(kept_str, notice, prefix: true), truncated: true,
                     omitted_lines: omitted_lines, omitted_chars: omitted_chars }
          end

          head_lines_count = max_l / 2
          tail_lines_count = max_l - head_lines_count

          head_chars = max_c / 2
          tail_chars = max_c - head_chars

          if lines.size == 1
            head_lines = lines
            tail_lines = lines
          elsif head_lines_count + tail_lines_count >= lines.size
            head_n = [head_lines_count, lines.size / 2].min
            tail_n = [tail_lines_count, lines.size - head_n].min
            head_lines = lines.first(head_n)
            tail_lines = lines.last(tail_n)
          else
            head_lines = lines.first(head_lines_count)
            tail_lines = lines.last(tail_lines_count)
          end

          head_str = head_lines.join
          tail_str = tail_lines.join

          if head_str.bytesize > head_chars
            head_str = head_str.byteslice(0, head_chars)
            head_str = head_str.scrub("") unless head_str.valid_encoding?
          end
          if tail_str.bytesize > tail_chars
            tail_str = tail_str.byteslice(-tail_chars, tail_chars)
            tail_str = tail_str.scrub("") unless tail_str.valid_encoding?
          end

          omitted_lines = if lines.size == 1
                            0
                          else
                            head_k = head_str.empty? ? 0 : head_str.lines(sep).size
                            tail_k = tail_str.empty? ? 0 : tail_str.lines(sep).size
                            [lines.size - (head_k + tail_k), 0].max
                          end
          omitted_chars = [str.bytesize - (head_str.bytesize + tail_str.bytesize), 0].max
          notice = "\n\n... [Truncated: #{omitted_lines} lines / #{omitted_chars} chars omitted to preserve token budget] ...\n\n"

          { text: "#{head_str}#{notice}#{tail_str}", truncated: true,
            omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        end
      end

      # Post-byteslice UTF-8 guard: a byte-boundary cut can split a multibyte
      # character at either edge of the kept region. Dropping the partial
      # sequence keeps the byte budget honest while the rendered output stays
      # valid UTF-8 — the property every consumer below this point (JSON
      # payload envelopes, regex-based token estimation, history joins)
      # silently assumes.
      def self.finalize(str, notice, prefix:)
        str = str.scrub("") unless str.valid_encoding?
        prefix ? "#{str}#{notice}" : "#{notice}#{str}"
      end
    end
  end
end
