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

      # Issue #634: a keepalive-only stream never produces an event, so the
      # full-body fallback buffer used to grow for the whole connection. Only
      # the tail is retained; once a real SSE event surfaces the fallback is
      # disabled, so the cap never affects genuine event parsing.
      MAX_RAW_BODY_BYTES = 64 * 1024

      def initialize(terminator: SSE_TERMINATOR)
        @terminator = terminator
        @terminator_bin = terminator.is_a?(String) ? terminator.b : terminator
        @sse_mode = @terminator == SSE_TERMINATOR || @terminator == SSE_EVENT_SEP
        @buffer = String.new(encoding: Encoding::ASCII_8BIT)
        # Full-body fallback (issue #556): a provider that ignores `stream:
        # true` answers with one plain JSON body carrying no SSE fields.
        # Remember that body until flush so the turn is not silently empty.
        @raw_body = String.new(encoding: Encoding::ASCII_8BIT)
        @any_event = false
      end

      # Feed raw bytes; returns an array of complete events parsed from this
      # chunk. Partial events stay in the buffer.
      def feed(chunk_bytes)
        bytes = chunk_bytes.to_s.b
        @buffer << bytes
        # Stop remembering once a real event surfaced — from then on this is
        # a genuine SSE stream and the fallback must never fire.
        if @sse_mode && !@any_event
          @raw_body << bytes
          @raw_body = @raw_body.byteslice(-MAX_RAW_BODY_BYTES, MAX_RAW_BODY_BYTES) if @raw_body.bytesize > MAX_RAW_BODY_BYTES
        end
        drain_complete_events(final: false)
      end

      # Flush any trailing event (no trailing terminator) and reset.
      def flush
        events = []
        unless @buffer.empty? && @raw_body.empty?
          events = drain_complete_events(final: true)

          unless @buffer.empty?
            remaining = @buffer.dup
            parsed = parse_event(remaining)
            events << parsed if parsed
            @any_event = true if parsed
          end

          # No SSE event ever surfaced but the body carried real content: emit
          # the whole body as one message event so formatters can parse it and
          # the turn reports text instead of an empty response.
          events << { type: "message", data: full_body_data(@raw_body) } if @sse_mode && !@any_event && substantive_body?(@raw_body)
        end

        @buffer = String.new(encoding: Encoding::ASCII_8BIT)
        @raw_body = String.new(encoding: Encoding::ASCII_8BIT)
        @any_event = false
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
            next unless parsed

            events << parsed
            @any_event = true
          end
        else
          while (idx = @buffer.index(@terminator_bin))
            event_block = @buffer.byteslice(0, idx)
            @buffer = @buffer.byteslice((idx + @terminator_bin.bytesize)..-1) || String.new(encoding: Encoding::ASCII_8BIT)
            parsed = parse_event(event_block)
            next unless parsed

            events << parsed
            @any_event = true
          end
        end
        events
      end

      # True when the raw body holds at least one line that is neither blank
      # nor an SSE comment. Pure keepalive/comment bodies must not trigger the
      # full-body fallback (they are not a provider answer).
      def substantive_body?(raw)
        utf8 = decode_utf8(raw)
        utf8.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?(":")

          return true
        end
        false
      end

      def full_body_data(raw)
        decode_utf8(raw).sub(/\s+\z/, "")
      end

      def decode_utf8(bytes)
        text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub
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
