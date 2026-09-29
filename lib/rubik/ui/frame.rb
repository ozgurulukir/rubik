# frozen_string_literal: true

require "io/console"

module Rubik
  module UI
    # Minimal rounded frame drawing used by the banner, approval cards and
    # the input-box prompt. The glyphs come from the active Theme (unicode
    # rounded or ascii), so the same code degrades gracefully on legacy
    # consoles.
    module Frame
      # Terminal width of the given output (or the controlling console).
      def self.width(io = nil)
        w = if io.respond_to?(:winsize)
              begin
                io.winsize[1]
              rescue SystemCallError, IOError
                nil
              end
            end
        w = w.to_i
        return w if w.positive?

        console = begin
          IO.console
        rescue SystemCallError
          nil
        end
        cols = console&.winsize&.[](1).to_i
        cols.positive? ? cols : 80
      end

      # Standalone top border with an optional title segment; shared by
      # #draw and the input-box prompt (ui.input_box).
      def self.top_border(theme, width:, title: nil)
        g = theme.glyphs
        inner = [width - 4, 8].max
        title_part = title ? "#{g[:dash]} #{title} " : ""
        title_pad = [inner + 1 - display_width(title_part), 0].max
        "#{g[:corner_tl]}#{g[:dash]}#{title_part}#{g[:dash] * title_pad}#{g[:corner_tr]}"
      end

      # Standalone bottom border matching #top_border.
      def self.bottom_border(theme, width:)
        g = theme.glyphs
        inner = [width - 4, 8].max
        "#{g[:corner_bl]}#{g[:dash] * (inner + 2)}#{g[:corner_br]}"
      end

      # Draws a one-cell padded frame around content lines.
      # Returns the frame as a single string (with trailing newline).
      def self.draw(lines, theme:, width: 60, title: nil)
        return "" if lines.empty?

        inner = [width - 4, 8].max
        content = lines.map { |l| truncate_plain(theme, l, inner) }

        out = +""
        out << "#{top_border(theme, width: width, title: title)}\n"
        content.each { |l| out << "#{theme.glyph(:rail)} #{l}#{' ' * [inner - display_width(l), 0].max} #{theme.glyph(:rail)}\n" }
        out << "#{bottom_border(theme, width: width)}\n"
        out
      end

      # Truncates to exactly `max` display cells, reserving room for the
      # theme's ellipsis glyph ("…" unicode / "..." ascii) so every row
      # keeps the frame's uniform width.
      def self.truncate_plain(theme, str, max)
        ellipsis = theme.glyph(:ellipsis)
        return str if display_width(str) <= max

        "#{str[0...(max - display_width(ellipsis))]}#{ellipsis}"
      rescue ArgumentError
        str[0...max]
      end

      # East-Asian wide + common emoji blocks that render two columns wide
      # in terminals; padding must account for them or the right rail
      # drifts (e.g. the 🎲 banner row).
      WIDE_RANGES = [
        [0x1100, 0x115F], [0x2E80, 0xA4CF], [0xAC00, 0xD7A3],
        [0xF900, 0xFAFF], [0xFE30, 0xFE4F], [0xFF00, 0xFF60],
        [0xFFE0, 0xFFE6], [0x1F300, 0x1F64F], [0x1F680, 0x1F6FF],
        [0x1F900, 0x1F9FF], [0x20000, 0x3FFFD]
      ].freeze

      def self.display_width(str)
        Capability.strip_ansi(str.to_s).each_char.sum do |chr|
          ord = chr.ord
          WIDE_RANGES.any? { |(a, b)| ord.between?(a, b) } ? 2 : 1
        end
      end
    end
  end
end
