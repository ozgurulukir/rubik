# frozen_string_literal: true

module Rubik
  module Tools
    module Truncator
      DEFAULT_MAX_CHARS = 12_000
      DEFAULT_MAX_LINES = 300

      def self.truncate(text, max_chars: DEFAULT_MAX_CHARS, max_lines: DEFAULT_MAX_LINES, strategy: :head_tail, separator: "\n")
        str = text.to_s
        # byteslice truncation below cuts on byte boundaries and can split a
        # multibyte character, producing invalid UTF-8 that then poisons the
        # whole downstream pipeline (JSON generation, regex work, token
        # estimation). Scrub exactly once, after the last byteslice.
        str = str.scrub("") unless str.valid_encoding?

        max_c = (max_chars || DEFAULT_MAX_CHARS).to_i
        max_l = (max_lines || DEFAULT_MAX_LINES).to_i
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
          kept_str = kept_str.byteslice(0, max_c) if kept_str.bytesize > max_c
          kept_line_count = kept_str.empty? ? 0 : kept_str.lines(sep).size
          omitted_lines = [lines.size - kept_line_count, 0].max
          omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
          notice = "\n... [Truncated: omitted #{omitted_lines} lines / #{omitted_chars} chars] ...\n"
          { text: finalize(kept_str, notice, prefix: true), truncated: true,
            omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        when :tail_only
          kept_lines = lines.last(max_l)
          kept_str = kept_lines.join
          kept_str = kept_str.byteslice(-max_c, max_c) if kept_str.bytesize > max_c
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
            kept_str = kept_str.byteslice(0, max_c) if kept_str.bytesize > max_c
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

          head_str = head_str.byteslice(0, head_chars) if head_str.bytesize > head_chars
          tail_str = tail_str.byteslice(-tail_chars, tail_chars) if tail_str.bytesize > tail_chars

          omitted_lines = if lines.size == 1
                            0
                          else
                            head_k = head_str.empty? ? 0 : head_str.lines(sep).size
                            tail_k = tail_str.empty? ? 0 : tail_str.lines(sep).size
                            [lines.size - (head_k + tail_k), 0].max
                          end
          omitted_chars = [str.bytesize - (head_str.bytesize + tail_str.bytesize), 0].max
          notice = "\n\n... [Truncated: #{omitted_lines} lines / #{omitted_chars} chars omitted to preserve token budget] ...\n\n"

          head_final = head_str.valid_encoding? ? head_str : head_str.scrub("")
          tail_final = tail_str.valid_encoding? ? tail_str : tail_str.scrub("")
          { text: "#{head_final}#{notice}#{tail_final}", truncated: true,
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
