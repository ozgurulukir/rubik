# frozen_string_literal: true

require "net/http"

module Rubik
  module LLM
    # ---- Persistent connection pool ---------------------------------------
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
    class ConnectionPool
      CONNECTION_IDLE_TIMEOUT = 300

      @pool_mutex = Mutex.new
      @pool = {}
      @pool_locks = {}
      @pool_locks_guard = Mutex.new
      @integrity_lost_errors = nil

      class << self
        # After any of these the socket's integrity is unknown (or the stream
        # was cut mid-read by Ctrl+C): never hand the session back to the pool.
        # Resolved lazily (not a load-time constant) because HTTPClient::
        # RETRYABLE_ERRORS lives in client.rb, which requires this file before
        # defining the HTTPClient class.
        def integrity_lost_errors
          # StreamCallbackError (issue #587): a consumer chunk-callback
          # exception escapes mid-body, so the SSE framing state is unknown.
          # It is deliberately narrower than ClientError — a status-decided
          # ClientError is raised after a full body drain and the session is
          # reusable — so pooling is not penalized on ordinary HTTP failures.
          @integrity_lost_errors ||= [
            *HTTPClient::RETRYABLE_ERRORS, Net::ReadTimeout, IOError,
            OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Interrupt,
            Rubik::LLM::StreamCallbackError
          ].freeze
        end

        # Yields an HTTP session for (host, port, scheme), reusing the pooled
        # keep-alive session when one exists. Same-thread re-entry falls back
        # to a private single-use connection (see the class comment).
        def with_connection(uri, timeout:, open_timeout:)
          key = [uri.host, uri.port, uri.scheme == "https"]
          lock = @pool_locks_guard.synchronize { @pool_locks[key] ||= Mutex.new }

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
              rescue *integrity_lost_errors
                drop(key, http)
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

        def drop(key, http)
          @pool_mutex.synchronize { @pool.delete(key) if @pool[key].equal?(http) }
          http.finish if http&.started?
        rescue StandardError
          nil
        end

        # Builds the real Net::HTTP transport. open_timeout is bounded LOW and
        # independent of the (long) read timeout: Net::HTTP arms a Timeout thread
        # around TCP connect on Ruby 3.3; a short arming window shrinks the chance
        # that a stale Net::OpenTimeout is injected into unrelated main-thread
        # code after an Interrupt escapes the connect region.
        def default_http(uri, timeout:, open_timeout:)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = open_timeout
          http.read_timeout = timeout
          http
        end
      end
    end
  end
end
