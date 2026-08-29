# frozen_string_literal: true

module Rubik
  module Tools
    module Truncator
      DEFAULT_MAX_CHARS = 12_000
      DEFAULT_MAX_LINES = 300

      def self.truncate(text, max_chars: DEFAULT_MAX_CHARS, max_lines: DEFAULT_MAX_LINES, strategy: :head_tail)
        str = text.to_s
        lines = str.lines

        max_c = (max_chars || DEFAULT_MAX_CHARS).to_i
        max_l = (max_lines || DEFAULT_MAX_LINES).to_i

        return { text: str, truncated: false, omitted_lines: 0, omitted_chars: 0 } if str.bytesize <= max_c && lines.size <= max_l

        strategy_sym = strategy.to_s.downcase.to_sym

        case strategy_sym
        when :head_only
          kept_lines = lines.first(max_l)
          kept_str = kept_lines.join
          kept_str = kept_str.byteslice(0, max_c) if kept_str.bytesize > max_c
          omitted_lines = [lines.size - kept_lines.size, 0].max
          omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
          notice = "\n... [Truncated: omitted #{omitted_lines} lines / #{omitted_chars} chars] ...\n"
          { text: "#{kept_str}#{notice}", truncated: true, omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        when :tail_only
          kept_lines = lines.last(max_l)
          kept_str = kept_lines.join
          kept_str = kept_str.byteslice(-max_c, max_c) if kept_str.bytesize > max_c
          omitted_lines = [lines.size - kept_lines.size, 0].max
          omitted_chars = [str.bytesize - kept_str.bytesize, 0].max
          notice = "\n... [Truncated: omitted #{omitted_lines} lines / #{omitted_chars} chars] ...\n"
          { text: "#{notice}#{kept_str}", truncated: true, omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        else # :head_tail
          half_lines = (max_l / 2).clamp(1, 150)
          half_chars = (max_c / 2).clamp(1, 6000)

          head_lines = lines.first(half_lines)
          tail_lines = lines.last(half_lines)

          head_str = head_lines.join
          tail_str = tail_lines.join

          head_str = head_str.byteslice(0, half_chars) if head_str.bytesize > half_chars
          tail_str = tail_str.byteslice(-half_chars, half_chars) if tail_str.bytesize > half_chars

          omitted_lines = [lines.size - (head_lines.size + tail_lines.size), 0].max
          omitted_chars = [str.bytesize - (head_str.bytesize + tail_str.bytesize), 0].max
          notice = "\n\n... [Truncated: #{omitted_lines} lines / #{omitted_chars} chars omitted to preserve token budget] ...\n\n"

          { text: "#{head_str}#{notice}#{tail_str}", truncated: true, omitted_lines: omitted_lines, omitted_chars: omitted_chars }
        end
      end
    end
  end
end
