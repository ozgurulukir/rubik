# frozen_string_literal: true

require "tty-markdown"

module Rubik
  module UI
    # Line-oriented live markdown renderer for the streaming token flow.
    # Completed lines are styled the moment their newline arrives (bold
    # headings, inline code, fenced code rails); the tail is flushed on
    # chunk_end. When styling is disabled (non-TTY / ui.markdown: off) every
    # segment passes through verbatim so piped output stays byte-identical
    # with the pre-UI streaming behavior.
    class MarkdownStream
      def initialize(theme, enabled: true)
        @theme = theme
        @enabled = enabled && theme.color?
        @pending = +""
        @in_fence = false
      end

      # Feeds a streaming delta. Yields ready-to-print segments (including
      # their trailing newline) to the block as they complete.
      def push(delta)
        return if delta.nil? || delta.empty?

        @pending << delta
        while (idx = @pending.index("\n"))
          line = @pending.slice!(0..idx)
          yield render_segment(line)
        end
      end

      # Flushes the buffered tail at end-of-stream. Yields the final segment
      # (plus a terminating newline when anything was streamed mid-line) so
      # the caller never leaves the cursor hanging.
      def finish
        return if @pending.empty?

        tail = @pending
        @pending = +""
        yield "#{render_segment(tail)}\n"
      end

      # Renders a complete markdown document in one shot (batch mode /
      # command output). Falls back to the raw text when styling is off.
      def self.render_document(text, theme, enabled: true)
        return text if text.nil? || text.empty?
        return text unless enabled && theme.color?

        TTY::Markdown.parse(text)
      end

      private

      def render_segment(segment)
        return segment unless @enabled

        line = segment.chomp
        rendered =
          if line.start_with?("```")
            @in_fence = !@in_fence
            @theme.paint(line, :dim)
          elsif @in_fence
            "#{@theme.paint("#{@theme.glyph(:rail)} ", :dim)}#{@theme.paint(line, :dim)}"
          elsif line =~ /\A(#+)\s+(.*)\z/
            @theme.paint("#{Regexp.last_match(1)} #{Regexp.last_match(2)}", :bold)
          else
            style_inline(line)
          end
        "#{rendered}#{"\n" if segment.end_with?("\n")}"
      end

      # Inline styles: **bold**, `code`. Conservative regexes; unmatched
      # markers stay visible rather than swallowing text.
      def style_inline(line)
        out = line.gsub(/\*\*([^*]+)\*\*/) { @theme.paint(Regexp.last_match(1), :bold) }
        out.gsub(/`([^`]+)`/) { |seg| @theme.paint(seg, :info) }
      end
    end
  end
end
