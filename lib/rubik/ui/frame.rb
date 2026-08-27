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
              rescue StandardError
                nil
              end
            end
        w = w.to_i
        return w if w.positive?

        console = begin
          IO.console
        rescue StandardError
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
      rescue StandardError
        str[0...max]
      end

      # Rough display width: counts codepoints of the ANSI-stripped string;
      # halving wide glyphs is unnecessary for the box content we draw
      # (ASCII + basic unicode).
      def self.display_width(str)
        Capability.strip_ansi(str.to_s).length
      end
    end
  end
end
