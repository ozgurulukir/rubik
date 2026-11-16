# frozen_string_literal: true

require "net/http"
require "json"
require "time"
require "uri"
require_relative "../platform"
require_relative "sse_parser"
require_relative "connection_pool"

module Rubik
  module LLM
    # Transport failure classification (issue #106): the client raises
    # message-string ClientErrors, so callers cannot read the message to
    # tell a transient transport failure (DNS, connection reset, exhausted
    # 5xx, rate limit) from a permanent one (4xx content/auth/moderation,
    # read timeout, malformed response). The flag is decided AT THE RAISE
    # POINT — precedent: RateLimitError's retry_after: kwarg. Default is
    # permanent (false); only the raise sites that provably saw a
    # transport-class failure opt into transient.
    class ClientError < StandardError
      attr_reader :transient

      def initialize(message, transient: false)
        super(message)
        @transient = transient == true
      end

      def transient? = @transient
    end

    # HTTP 429 (rate limited), carrying the parsed Retry-After hint when the
    # server advertised one. Subclass of ClientError so every existing
    # `rescue ClientError` site keeps working; the typed class lets callers
    # distinguish "provider throttled us" from every other failure without
    # parsing message strings. Rate limiting is transient by nature — the
    # subclass answers transient? true without a kwarg at every raise site.
    class RateLimitError < ClientError
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        super(message, transient: true)
        @retry_after = retry_after
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

      # Shared hosted-model concurrency limits (429) arrive in bursts lasting
      # seconds to minutes and advertise their window via `Retry-After`. The
      # generic budget (max_retries: 2, ~1.2s backoff) gives up mid-burst and
      # loses the turn; rate limiting gets its own, larger budget and honors
      # the server's hint, capped so a pathological header can't stall an
      # interactive agent turn indefinitely.
      RATE_LIMIT_MAX_DELAY_S = 60

      # Read a response header defensively: test doubles and exotic response
      # objects may not implement the Net::HTTPHeader interface.
      def self.header_value(res, name)
        res.respond_to?(:key?) && res.key?(name) ? res[name] : nil
      rescue StandardError
        nil
      end

      # Retry-After may be delay-seconds or an HTTP-date; anything else is
      # unparseable -> nil (caller falls back to exponential backoff).
      def self.parse_retry_after(value)
        return nil if value.nil?

        s = value.to_s.strip
        return s.to_f if s.match?(/\A\d+(\.\d+)?\z/)

        t = Time.httpdate(s)
        d = (t - Time.now).ceil
        d.positive? ? d : 0
      rescue StandardError
        nil
      end

      # Delay before re-sending after a 429: the server's Retry-After hint
      # when present (honored exactly — the server knows its own window);
      # otherwise exponential backoff with ±20% jitter to de-synchronize
      # concurrent clients hammering the same endpoint. Both capped.
      def self.retry_delay_after(res, retries, backoff_base)
        hint = parse_retry_after(header_value(res, "Retry-After"))
        delay = hint
        unless delay
          delay = backoff_base * (2**(retries - 1))
          delay *= (0.8 + (0.4 * rand))
        end
        delay.clamp(0, RATE_LIMIT_MAX_DELAY_S)
      end

      # `retries` is nil on paths that never entered the retry loop (streaming)
      # — the message then omits the attempt count instead of falsely claiming
      # "gave up after 0 retries" (fresh-eye R5).
      #
      # `body` overrides `res.body` for the streaming path: inside Net::HTTP's
      # block form (`http.request { |response| ... }`) the accessor returns an
      # unmaterialized Net::ReadAdapter sink, not the transferred bytes, so the
      # caller must pass the chunks it drained (fresh-eye R7 — a live 429 paste
      # showed "#<Net::ReadAdapter:0x...>" instead of the provider's error JSON).
      def self.rate_limit_error(res, retries, body = nil)
        hint = parse_retry_after(header_value(res, "Retry-After"))
        detail = hint ? "server hinted #{hint}s" : "no Retry-After hint"
        budget = retries ? " (gave up after #{retries} rate-limit retries)" : ""
        RateLimitError.new(
          "HTTP 429 rate limited#{budget}, #{detail}: #{Rubik::Platform.safe_utf8(body || res.body)}",
          retry_after: hint
        )
      end

      def self.parse_and_validate_uri(url_str)
        uri = URI.parse(url_str.to_s)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise ClientError, "Invalid endpoint URL '#{url_str}'. URL must start with http:// or https:// (e.g. https://api.openai.com/v1/chat/completions)"
        end

        uri
      rescue URI::InvalidURIError => e
        raise ClientError, "Invalid endpoint URL '#{url_str}': #{e.message}"
      end

      def self.perform_post_request(uri, headers, payload, timeout:, open_timeout:, http_factory:)
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
      end

      # Rate limiting is transitory and self-healing — it gets its own
      # larger budget (max_429_retries), a Retry-After-aware delay, and
      # a typed error when exhausted so callers can report "provider
      # throttled" distinctly. The generic 5xx budget is untouched, so
      # one 429 burst cannot exhaust the transport-failure budget.
      def self.handle_429_retry(res, rate_limit_retries:, max_429_retries:, start_time:, backoff_base:, max_wall_clock:, on_retry:)
        if rate_limit_retries < max_429_retries
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
          delay = retry_delay_after(res, rate_limit_retries + 1, backoff_base)
          if elapsed + delay <= max_wall_clock
            rate_limit_retries += 1
            on_retry&.call(rate_limit_retries, max_429_retries, "HTTP 429")
            sleep(delay)
            return rate_limit_retries
          end
        end
        raise rate_limit_error(res, rate_limit_retries)
      end

      def self.attempt_backoff_retry(retries:, max_retries:, start_time:, backoff_base:, max_wall_clock:, reason:, on_retry:)
        return nil unless retries < max_retries

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        delay = backoff_base * (2**retries) * (0.8 + (0.4 * rand))
        return nil if elapsed + delay > max_wall_clock

        retries += 1
        on_retry&.call(retries, max_retries, reason)
        sleep(delay)
        retries
      end

      # A body without a charset arrives tagged ASCII-8BIT; embedding it
      # raw makes every ClientError message binary and the UTF-8 output
      # layer raises inside the REPL's rescue clause (masking the real
      # HTTP error as Encoding::CompatibilityError).
      # Exhausted 5xx is transport-class (provider outage) → transient;
      # a 4xx is content/auth/moderation → permanent. One raise point
      # for both, the flag decided by status (issue #106).
      def self.parse_json_response(res, uri:, status:)
        unless status >= 200 && status < 300
          raise ClientError.new(
            "HTTP Request failed with code #{res.code}: #{Rubik::Platform.safe_utf8(res.body)}",
            transient: status >= 500
          )
        end

        begin
          JSON.parse(res.body)
        rescue JSON::ParserError => e
          raise ClientError, "Invalid JSON response from #{uri.host} (HTTP #{status}): #{e.message}"
        end
      end

      def self.post_json(url_str, headers: {}, payload: {}, timeout: 30, open_timeout: 10,
                         max_retries: 2, max_429_retries: 5, backoff_base: 0.2, max_wall_clock: 120,
                         on_retry: nil, http_factory: nil)
        uri = parse_and_validate_uri(url_str)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        retries = 0
        rate_limit_retries = 0

        loop do
          res = perform_post_request(uri, headers, payload, timeout: timeout, open_timeout: open_timeout, http_factory: http_factory)
          status = res.code.to_i

          if status == 429
            rate_limit_retries = handle_429_retry(
              res, rate_limit_retries: rate_limit_retries, max_429_retries: max_429_retries,
                   start_time: start_time, backoff_base: backoff_base, max_wall_clock: max_wall_clock,
                   on_retry: on_retry
            )
            next
          end

          if status >= 500
            new_retries = attempt_backoff_retry(
              retries: retries, max_retries: max_retries, start_time: start_time,
              backoff_base: backoff_base, max_wall_clock: max_wall_clock, reason: "HTTP #{status}",
              on_retry: on_retry
            )
            if new_retries
              retries = new_retries
              next
            end
          end

          return parse_json_response(res, uri: uri, status: status)
        rescue ClientError
          raise
        rescue Net::ReadTimeout
          # Server accepted the request and is still working. NEVER retry:
          raise ClientError, "read timeout after #{timeout}s calling #{uri.host} (model/server still working? request not retried)"
        rescue Interrupt
          raise # rubocop:disable Lint/DuplicateBranch -- Ctrl+C yayilimi bilinçli olarak ayri tutuldu, even mid-backoff
        rescue *RETRYABLE_ERRORS => e
          new_retries = attempt_backoff_retry(
            retries: retries, max_retries: max_retries, start_time: start_time,
            backoff_base: backoff_base, max_wall_clock: max_wall_clock, reason: e.class.name,
            on_retry: on_retry
          )
          if new_retries
            retries = new_retries
            next
          end
          raise ClientError.new(
            "Network error calling #{uri.host}: #{e.class} #{e.message} (gave up after #{retries} retr#{retries == 1 ? 'y' : 'ies'})",
            transient: true
          )
        rescue StandardError => e
          raise ClientError, "Network error calling #{uri.host}: #{e.class} #{e.message}"
        end
      end

      def self.default_http(uri, timeout:, open_timeout:)
        ConnectionPool.default_http(uri, timeout: timeout, open_timeout: open_timeout)
      end

      def self.with_pooled_connection(uri, timeout:, open_timeout:, &)
        ConnectionPool.with_connection(uri, timeout: timeout, open_timeout: open_timeout, &)
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
      def self.post_stream_json(url_str, headers: {}, payload: {}, timeout: 120, open_timeout: 15,
                                idle_timeout: nil,
                                terminator: SSEParser::SSE_TERMINATOR, http_factory: nil, &)
        uri = parse_and_validate_uri(url_str)

        effective_timeout = idle_timeout || timeout
        state = { surfaced: false }
        req = build_post_request(uri, headers, payload, accept: "text/event-stream")
        attempts = 0

        begin
          attempts += 1
          if http_factory
            http = http_factory.call(uri)
            http.read_timeout = effective_timeout if http.respond_to?(:read_timeout=)
            http.open_timeout = open_timeout if http.respond_to?(:open_timeout=)
            stream_attempt(http, uri, req, terminator: terminator, state: state, &)
          else
            with_pooled_connection(uri, timeout: effective_timeout, open_timeout: open_timeout) do |http|
              stream_attempt(http, uri, req, terminator: terminator, state: state, &)
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
          raise ClientError.new("Network error during stream from #{uri.host}: #{e.message}", transient: true)
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
              # Streaming never retries a 429 (once headers surface, events
              # may already be consumed) — but the failure is still typed as
              # RateLimitError for callers to report distinctly. retries: nil
              # because the streaming path has no retry loop (fresh-eye R5);
              # the drained chunks are the real body — in block form res.body
              # is a Net::ReadAdapter sink, not the bytes (fresh-eye R7).
              raise rate_limit_error(response, nil, body_chunks.join) if status_code == 429

              # Same status-decided split as the batch path (issue #106):
              # exhausted 5xx → transient, 4xx → permanent.
              raise ClientError.new(
                "HTTP Request failed with code #{status_code}: #{Rubik::Platform.safe_utf8(body_chunks.join)}",
                transient: status_code >= 500
              )
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
