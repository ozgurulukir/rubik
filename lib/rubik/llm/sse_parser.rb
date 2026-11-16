# frozen_string_literal: true

module Rubik
  module LLM
    # Buffers raw bytes from a stream and emits complete events.
    # Default delimiter is the SSE blank line (\n\n); pass
    # `terminator: "\n"` to parse NDJSON streams (one JSON object per line).
    # One event is a Hash like:
    #   { type: "message", data: "json-string" }
    # In SSE mode, multi-line `data:` fields are joined with \n. In NDJSON
    # mode (`terminator: "\n"`), the `type` field is always "message" and
    # the entire line is the `data`. Incomplete events are held in the
    # internal buffer until the next feed.
    class SSEParser
      SSE_EVENT_SEP = /\r\n\r\n|\n\n|\r\n\n|\n\r\n|\r\r/
      SSE_EVENT_SEP_BIN = Regexp.new(SSE_EVENT_SEP.source.b, Regexp::NOENCODING)
      SSE_TERMINATOR = "\n\n"
      NDJSON_TERMINATOR = "\n"

      def initialize(terminator: SSE_TERMINATOR)
        @terminator = terminator
        @terminator_bin = terminator.is_a?(String) ? terminator.b : terminator
        @sse_mode = @terminator == SSE_TERMINATOR || @terminator == SSE_EVENT_SEP
        @buffer = String.new(encoding: Encoding::ASCII_8BIT)
      end

      # Feed raw bytes; returns an array of complete events parsed from this
      # chunk. Partial events stay in the buffer.
      def feed(chunk_bytes)
        @buffer << chunk_bytes.to_s.b
        drain_complete_events(final: false)
      end

      # Flush any trailing event (no trailing terminator) and reset.
      def flush
        return [] if @buffer.empty?

        events = drain_complete_events(final: true)

        unless @buffer.empty?
          remaining = @buffer.dup
          @buffer = String.new(encoding: Encoding::ASCII_8BIT)
          parsed = parse_event(remaining)
          events << parsed if parsed
        end

        events
      end

      private

      # The one drain loop, shared by feed and flush. The SSE and NDJSON
      # branches differ only in how they locate the next terminator. The
      # chunk-boundary \r guard applies only while feeding: if the match
      # ends on \r at the very end of the buffer, wait for the next feed
      # to see if \n follows (e.g. \r\r could become \r\r\n). At flush
      # there is no next feed, so the trailing \r is a real separator.
      def drain_complete_events(final:)
        events = []
        if @sse_mode
          while (m = @buffer.match(SSE_EVENT_SEP_BIN))
            break if !final && m.end(0) == @buffer.bytesize && @buffer.end_with?("\r".b)

            event_block = @buffer.byteslice(0, m.begin(0))
            @buffer = @buffer.byteslice(m.end(0)..-1) || String.new(encoding: Encoding::ASCII_8BIT)
            parsed = parse_event(event_block)
            events << parsed if parsed
          end
        else
          while (idx = @buffer.index(@terminator_bin))
            event_block = @buffer.byteslice(0, idx)
            @buffer = @buffer.byteslice((idx + @terminator_bin.bytesize)..-1) || String.new(encoding: Encoding::ASCII_8BIT)
            parsed = parse_event(event_block)
            events << parsed if parsed
          end
        end
        events
      end

      def parse_event(block)
        return nil if block.nil?

        utf8 = block.to_s.dup.force_encoding(Encoding::UTF_8)
        utf8 = utf8.scrub unless utf8.valid_encoding?
        return { type: "message", data: utf8.chomp } unless @sse_mode

        lines = utf8.split(/\r\n|\r|\n/)
        return nil if lines.empty?

        event_type = "message"
        data_lines = []
        has_field = false

        lines.each do |line|
          next if line.empty?
          next if line.start_with?(":")

          if (m = line.match(/\Aevent:\s*(.+)\z/))
            event_type = m[1]
            has_field = true
          elsif (m = line.match(/\Adata:\s?(.*)\z/))
            data_lines << m[1]
            has_field = true
          end
        end

        return nil unless has_field

        { type: event_type, data: data_lines.join("\n") }
      end
    end
  end
end
