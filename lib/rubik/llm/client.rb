# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Rubik
  module LLM
    class ClientError < StandardError; end

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
      SSE_TERMINATOR = "\n\n".freeze
      NDJSON_TERMINATOR = "\n".freeze

      def initialize(terminator: SSE_TERMINATOR)
        @terminator = terminator
        @sse_mode = (@terminator == SSE_TERMINATOR)
        @buffer = String.new(encoding: Encoding::UTF_8)
      end

      # Feed raw bytes; returns an array of complete events parsed from this
      # chunk. Partial events stay in the buffer.
      def feed(chunk_bytes)
        incoming = chunk_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        @buffer << incoming
        events = []
        while (idx = @buffer.index(@terminator))
          event_block = @buffer[0...idx]
          @buffer = @buffer[(idx + @terminator.length)..]
          events << parse_event(event_block)
        end
        events
      end

      # Flush any trailing event (no trailing terminator) and reset.
      def flush
        return [] if @buffer.empty?
        remaining = @buffer.dup
        @buffer = String.new(encoding: Encoding::UTF_8)
        [parse_event(remaining)]
      end

      private

      def parse_event(block)
        return { type: "message", data: block.to_s.chomp } unless @sse_mode

        event_type = "message"
        data_lines = []
        block.each_line do |line|
          line = line.chomp
          next if line.empty?
          if (m = line.match(/\Aevent:\s*(.+)\z/))
            event_type = m[1]
          elsif (m = line.match(/\Adata:\s?(.*)\z/))
            data_lines << m[1]
          end
          # Ignore other SSE fields (id:, retry:, comments starting with :)
        end
        { type: event_type, data: data_lines.join("\n") }
      end
    end

    class HTTPClient
      def self.post_json(url_str, headers: {}, payload: {}, timeout: 30, max_retries: 3)
        begin
          uri = URI.parse(url_str.to_s)
        rescue StandardError => e
          raise ClientError, "Invalid endpoint URL '#{url_str}': #{e.message}"
        end

        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise ClientError, "Invalid endpoint URL '#{url_str}'. URL must start with http:// or https:// (e.g. https://api.openai.com/v1/chat/completions)"
        end

        retries = 0

        loop do
          begin
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.open_timeout = timeout
            http.read_timeout = timeout

            req = Net::HTTP::Post.new(uri.request_uri)
            headers.each { |k, v| req[k] = v }
            req["Content-Type"] = "application/json"
            req["User-Agent"] ||= "Rubik/1.0 (Windows; x64; Agentic CLI)"
            req.body = JSON.dump(payload)

            res = http.request(req)

            if res.code.to_i >= 500 || res.code.to_i == 429
              if retries < max_retries
                retries += 1
                sleep(0.1 * (2**retries))
                next
              end
            end

            unless res.is_a?(Net::HTTPSuccess)
              raise ClientError, "HTTP Request failed with code #{res.code}: #{res.body}"
            end

            return JSON.parse(res.body)
          rescue ClientError
            raise
          rescue StandardError => e
            if retries < max_retries
              retries += 1
              sleep(0.1 * (2**retries))
              next
            end
            raise ClientError, "Network error calling #{uri.host}: #{e.message}"
          end
        end
      end

      # Streaming variant of `post_json`. Yields each SSE event (as a Hash
      # `{ type:, data: }`) to the block. Does NOT retry — partial chunks
      # are dangerous in a stream; the caller must handle reconnection.
      #
      # The transport uses `Net::HTTP`'s block form of `#request`, which
      # gives access to streaming response bytes. We feed them to an
      # `SSEParser` and yield complete events as they emerge.
      #
      # If the response is not an SSE event stream (no events arrive before
      # EOF), the full body is still yielded as a single `{ type: "message",
      # data: <body> }` event, so NDJSON-style consumers can read the
      # last "chunk" via `flush`.
      def self.post_stream_json(url_str, headers: {}, payload: {}, timeout: 60, terminator: SSEParser::SSE_TERMINATOR)
        begin
          uri = URI.parse(url_str.to_s)
        rescue StandardError => e
          raise ClientError, "Invalid endpoint URL '#{url_str}': #{e.message}"
        end

        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise ClientError, "Invalid endpoint URL '#{url_str}'. URL must start with http:// or https://"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = timeout
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        req["Content-Type"] = "application/json"
        req["Accept"] = "text/event-stream"
        req["User-Agent"] ||= "Rubik/1.0 (Windows; x64; Agentic CLI)"
        req.body = JSON.dump(payload)

        # Track status so we can raise on non-2xx AFTER consuming headers.
        status_code = nil
        message = nil
        body_chunks = []
        yielded_event_count = 0
        parser = SSEParser.new(terminator: terminator)

        begin
          http.request(req) do |response|
            status_code = response.code.to_i
            message = response.message

            unless status_code >= 200 && status_code < 300
              # Drain the body so the connection can be released, then raise.
              response.read_body { |chunk| body_chunks << chunk }
              body = body_chunks.join
              raise ClientError, "HTTP Request failed with code #{status_code}: #{body}"
            end

            response.read_body do |chunk|
              events = parser.feed(chunk)
              events.each do |event|
                yielded_event_count += 1
                yield event
              end
            end
          end

          # After the connection closes, flush any trailing event.
          parser.flush.each do |event|
            yielded_event_count += 1
            yield event
          end
        rescue ClientError
          raise
        rescue StandardError => e
          raise ClientError, "Network error during stream from #{uri.host}: #{e.message}"
        end

        :ok
      end
    end
  end
end
