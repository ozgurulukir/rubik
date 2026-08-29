# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "../platform"

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
      SSE_TERMINATOR = "\n\n"
      NDJSON_TERMINATOR = "\n"

      def initialize(terminator: SSE_TERMINATOR)
        @terminator = terminator
        @sse_mode = (@terminator == SSE_TERMINATOR)
        @buffer = String.new(encoding: Encoding::UTF_8)
      end

      # Feed raw bytes; returns an array of complete events parsed from this
      # chunk. Partial events stay in the buffer.
      def feed(chunk_bytes)
        incoming = chunk_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        incoming = incoming.scrub unless incoming.valid_encoding?
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
      # Errors that are safe to retry with an idempotent bounded backoff:
      # connect-phase failures and transport resets. Net::ReadTimeout is
      # deliberately NOT here: a read timeout on a non-streaming LLM call
      # means the server is still generating, and re-sending the full payload
      # would silently duplicate work (the original 2-minute freeze).
      RETRYABLE_ERRORS = [
        Net::OpenTimeout,
        Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ECONNREFUSED,
        Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
        SocketError,
        EOFError
      ].freeze

      def self.post_json(url_str, headers: {}, payload: {}, timeout: 30, open_timeout: 10,
                         max_retries: 2, backoff_base: 0.2, on_retry: nil, http_factory: nil)
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
          res =
            if http_factory
              http = http_factory.call(uri)
              req = build_post_request(uri, headers, payload)
              http.request(req)
            else
              with_pooled_connection(uri, timeout: timeout, open_timeout: open_timeout) do |http|
                req = build_post_request(uri, headers, payload)
                http.request(req)
              end
            end

          status = res.code.to_i

          if (status >= 500 || status == 429) && (retries < max_retries)
            retries += 1
            on_retry&.call(retries, max_retries, "HTTP #{status}")
            sleep(backoff_base * (2**(retries - 1)))
            next
          end

          raise ClientError, "HTTP Request failed with code #{res.code}: #{res.body}" unless status >= 200 && status < 300

          begin
            return JSON.parse(res.body)
          rescue JSON::ParserError => e
            raise ClientError, "Invalid JSON response from #{uri.host} (HTTP #{status}): #{e.message}"
          end
        rescue ClientError
          raise
        rescue Net::ReadTimeout
          # Server accepted the request and is still working. NEVER retry:
          raise ClientError, "read timeout after #{timeout}s calling #{uri.host} (model/server still working? request not retried)"
        rescue Interrupt
          raise # Ctrl+C must always propagate immediately, even mid-backoff
        rescue *RETRYABLE_ERRORS => e
          if retries < max_retries
            retries += 1
            on_retry&.call(retries, max_retries, e.class.name)
            sleep(backoff_base * (2**(retries - 1)))
            next
          end
          raise ClientError, "Network error calling #{uri.host}: #{e.class} #{e.message} (gave up after #{retries} retr#{retries == 1 ? 'y' : 'ies'})"
        rescue StandardError => e
          raise ClientError, "Network error calling #{uri.host}: #{e.class} #{e.message}"
        end
      end

      # Builds the real Net::HTTP transport. open_timeout is bounded LOW and
      # independent of the (long) read timeout: Net::HTTP arms a Timeout thread
      # around TCP connect on Ruby 3.3; a short arming window shrinks the chance
      # that a stale Net::OpenTimeout is injected into unrelated main-thread
      # code after an Interrupt escapes the connect region.
      def self.default_http(uri, timeout:, open_timeout:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = open_timeout
        http.read_timeout = timeout
        http
      end

      # ---- Persistent connection pool -------------------------------------
      #
      # Opening a brand-new TCP(+TLS) connection per LLM round-trip costs
      # ~100-300 ms each, and an agent turn issues many round-trips. Sessions
      # here persist per (host, port, scheme); a mutex per key serializes
      # concurrent use because a single Net::HTTP session is not thread-safe
      # (same-endpoint calls wait for the current response to finish).
      # Ruby's non-reentrant Mutex would deadlock on same-thread re-entry
      # (nested provider call, Enumerator#next fibers) — those transparently
      # fall back to a private single-use connection. Transport failures and
      # interrupts drop the session so the next attempt dials fresh.
      CONNECTION_IDLE_TIMEOUT = 300

      # After any of these the socket's integrity is unknown (or the stream
      # was cut mid-read by Ctrl+C): never hand the session back to the pool.
      INTEGRITY_LOST_ERRORS = [
        *RETRYABLE_ERRORS, Net::ReadTimeout, IOError,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Interrupt
      ].freeze

      @pool_mutex = Mutex.new
      @pool = {}
      @pool_locks = {}
      @pool_locks_guard = Mutex.new

      def self.with_pooled_connection(uri, timeout:, open_timeout:)
        key = [uri.host, uri.port, uri.scheme == "https"]
        lock = @pool_locks_guard.synchronize { (@pool_locks[key] ||= Mutex.new) }

        begin
          lock.synchronize do
            http = @pool_mutex.synchronize { @pool[key] }
            if http&.started?
              http.read_timeout = timeout
              http.open_timeout = open_timeout
            else
              http = default_http(uri, timeout: timeout, open_timeout: open_timeout)
              http.keep_alive_timeout = CONNECTION_IDLE_TIMEOUT
              http.start
              @pool_mutex.synchronize { @pool[key] = http }
            end

            begin
              yield http
            rescue *INTEGRITY_LOST_ERRORS
              drop_pooled(key, http)
              raise
            end
          end
        rescue ThreadError
          # Re-entrant call on the same thread (nested LLM call from inside a
          # streaming callback, or a second Enumerator#next fiber) — the
          # per-key mutex cannot be taken. Serve this call on a private,
          # single-use connection instead of deadlocking.
          http = default_http(uri, timeout: timeout, open_timeout: open_timeout)
          http.start
          begin
            yield http
          ensure
            http.finish if http.started?
          end
        end
      end

      def self.drop_pooled(key, http)
        @pool_mutex.synchronize { @pool.delete(key) if @pool[key].equal?(http) }
        http.finish if http&.started?
      rescue StandardError
        nil
      end

      def self.build_post_request(uri, headers, payload, accept: nil)
        req = Net::HTTP::Post.new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        req["Content-Type"] = "application/json"
        req["Accept"] = accept if accept
        req["User-Agent"] ||= "Rubik/1.0 (Windows; x64; Agentic CLI)"
        req.body = Rubik::Platform.safe_json_dump(payload)
        req
      end

      # Streaming variant of `post_json`. Yields each SSE event (as a Hash
      # `{ type:, data: }`) to the block. Does NOT retry once any part of the
      # response has surfaced — partial chunks are dangerous in a stream.
      # Exception: a transport failure before ANY byte arrived (a stale
      # pooled socket hit at connect/request time) is retried once on a
      # fresh connection, since the caller has seen nothing yet.
      #
      # The transport uses `Net::HTTP`'s block form of `#request`, which
      # gives access to streaming response bytes. We feed them to an
      # `SSEParser` and yield complete events as they emerge.
      #
      # `open_timeout` bounds only the TCP/TLS connect phase and is therefore
      # deliberately LOW and independent of the (long) read timeout — same
      # rationale as in `default_http`: waiting out a 60 s open window after
      # e.g. a DNS failure is exactly the multi-second freeze users see as
      # "the app hangs".
      #
      # If the response is not an SSE event stream (no events arrive before
      # EOF), the full body is still yielded as a single `{ type: "message",
      # data: <body> }` event, so NDJSON-style consumers can read the
      # last "chunk" via `flush`.
      def self.post_stream_json(url_str, headers: {}, payload: {}, timeout: 60, open_timeout: 10,
                                terminator: SSEParser::SSE_TERMINATOR, http_factory: nil, &block)
        begin
          uri = URI.parse(url_str.to_s)
        rescue StandardError => e
          raise ClientError, "Invalid endpoint URL '#{url_str}': #{e.message}"
        end

        raise ClientError, "Invalid endpoint URL '#{url_str}'. URL must start with http:// or https://" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        state = { surfaced: false }
        req = build_post_request(uri, headers, payload, accept: "text/event-stream")
        attempts = 0

        begin
          attempts += 1
          if http_factory
            stream_attempt(http_factory.call(uri), uri, req, terminator: terminator, state: state, &block)
          else
            with_pooled_connection(uri, timeout: timeout, open_timeout: open_timeout) do |http|
              stream_attempt(http, uri, req, terminator: terminator, state: state, &block)
            end
          end
        rescue ClientError
          raise
        rescue *RETRYABLE_ERRORS, IOError => e
          # Transparent fresh-socket retry ONLY while literally nothing has
          # reached the caller: no headers, no events. A stale pooled idle
          # socket manifests exactly like this.
          clean_retry = !state[:surfaced] && attempts < 2
          retry if clean_retry
          raise ClientError, "Network error during stream from #{uri.host}: #{e.message}"
        rescue StandardError => e
          # Everything else is wrapped once without retrying. That includes
          # Net::ReadTimeout — same policy as post_json: the server may
          # already be generating, and re-sending would duplicate work while
          # doubling the user-visible freeze — and TLS handshake failures
          # raised by http.start inside the pool.
          raise ClientError, "Network error during stream from #{uri.host}: #{e.message}"
        end

        :ok
      end

      # A single streaming request over an established connection. Sets
      # `state[:surfaced]` once response headers arrive; from that point on
      # the caller may already have consumed events.
      def self.stream_attempt(http, uri, req, terminator:, state:, &callback)
        parser = SSEParser.new(terminator: terminator)

        begin
          http.request(req) do |response|
            state[:surfaced] = true
            status_code = response.code.to_i

            unless status_code >= 200 && status_code < 300
              # Drain the body so the connection can be released, then raise.
              body_chunks = []
              response.read_body { |chunk| body_chunks << chunk }
              raise ClientError, "HTTP Request failed with code #{status_code}: #{body_chunks.join}"
            end

            response.read_body do |chunk|
              parser.feed(chunk).each(&callback)
            end
          end

          # After the connection closes, flush any trailing event.
          parser.flush.each(&callback)
        rescue ClientError,
               *RETRYABLE_ERRORS, IOError, Net::ReadTimeout
          # Propagate untouched so the pooled layer can drop a suspect session
          # and the caller decides on a transparent fresh-socket retry.
          raise
        rescue StandardError => e
          raise ClientError, "Network error during stream from #{uri.host}: #{e.message}"
        end
      end
    end
  end
end
