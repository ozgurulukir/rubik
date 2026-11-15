# frozen_string_literal: true

require "open3"
require "json"
require_relative "../platform"
require_relative "../log"

module Rubik
  module LSP
    # JSON-RPC-over-stdio transport for LSP::Client (issue #470). Owns the
    # generic plumbing that has nothing to do with the LSP protocol:
    #
    # * process spawn/teardown (Open3 popen3, stderr drain, kill tree),
    # * the reader thread and its byte-exact Content-Length framing,
    # * the request/response correlation registry (@responses /
    #   @pending_requests / @reader_failure) guarded by @mutex + @cv,
    # * thread-safe framed writes (@write_mutex).
    #
    # Protocol concerns (the initialize handshake, document sync, diagnostics
    # routing, server-request handling) stay in Client, which delegates the
    # plumbing here and receives every non-response incoming message through
    # the on_message callback. stop (shutdown) remains the exact inverse of
    # start (spawn): every resource the transport opens is retracted in LIFO
    # order, and a failing inverse never aborts the unwind.
    class Transport
      class RequestError < StandardError
        attr_reader :reason

        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end

      attr_reader :mutex, :cv, :running

      def initialize(root_dir:, on_message:)
        @root_dir = root_dir
        @on_message = on_message
        @running = false
        @crashed = false
        @req_id = 0
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thr = nil
        @reader_thr = nil
        @stderr_drain = nil
        @reader_alive = false
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @cv = ConditionVariable.new
        @responses = {}
        @pending_requests = {}
        @reader_failure = nil
      end

      # Spawn the server process for +argv+ (already resolved to an absolute
      # binary by the caller), install the reader thread and the stderr
      # drain. Returns true; all failures raise and are handled by the
      # caller's handshake rescue.
      def spawn(argv)
        @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(sanitized_spawn_env, *argv, chdir: @root_dir)
        # Binary mode: LSP framing is byte-exact. Text-mode pipes on Windows
        # translate CRLF→LF on read, so Content-Length counts and read(len)
        # disagree and the JSON body arrives truncated (the reader's old
        # silent rescue-then-break hid this — no real server was ever
        # spawned in tests).
        @stdin.binmode
        @stdout.binmode
        @running = false
        @crashed = false
        @reader_alive = false

        start_reader_thread
        # An unread stderr pipe fills its OS buffer (~64KB) and blocks the
        # server itself mid-write; drain continuously, discard content.
        @stderr_drain = Rubik::Platform::IoDrain.start(@stderr)
        true
      end

      # Called by Client after a successful initialize handshake; only then
      # does alive? report true (mirrors the pre-extraction @running = true).
      def mark_running
        @running = true
      end

      def crashed?
        @crashed == true
      end

      def alive?
        return false unless @running
        return false unless @reader_alive

        if @wait_thr
          return false unless @wait_thr.alive?
          return false if @stdin&.closed? || @stdout&.closed?
        end

        true
      end

      # True when a previous spawn left live plumbing that stop must retract
      # before a new spawn (the `@wait_thr&.alive? || @reader_alive` half of
      # Client#start's stop-if condition).
      def stale?
        @wait_thr&.alive? || @reader_alive
      end

      # True when any teardown-able resource exists (the stop guard).
      def resources?
        @wait_thr || @reader_thr
      end

      # PID of the spawned server process, nil when nothing was spawned.
      def server_pid
        @wait_thr&.pid
      end

      # Clear correlation state before a (re)start. Also rewinds the request
      # id counter, mirroring the pre-extraction start() behavior.
      def reset_correlation
        @req_id = 0
        @mutex.synchronize do
          @responses.clear
          @pending_requests.clear
          @reader_failure = nil
        end
      end

      # Full teardown: retract every resource in LIFO order — stderr drain,
      # reader thread, pipes, then the server process tree. A failing
      # inverse must never abort the unwind (half-unwound transport state is
      # worse than a failed close).
      def shutdown
        @running = false
        @crashed = false
        @reader_alive = false
        # Drain first: its thread may be blocked in gets on @stderr.
        @stderr_drain&.stop
        @stderr_drain = nil
        begin
          @reader_thr&.kill
        rescue StandardError
          nil
        end

        [@stdin, @stdout, @stderr].each do |io|
          io.close
        rescue StandardError
          nil
        end

        begin
          @reader_thr&.join(0.5)
          @reader_thr = nil
        rescue StandardError
          nil
        end
        return unless @wait_thr&.alive?

        Rubik::Platform.kill_tree(@wait_thr.pid)
        begin
          @wait_thr.join
        rescue StandardError
          nil
        end
      end

      def send_request(method, params, timeout: 5)
        req_id = @mutex.synchronize do
          @req_id += 1
          @pending_requests[@req_id] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @req_id
        end
        msg = {
          jsonrpc: "2.0",
          id: req_id,
          method: method,
          params: params
        }
        unless write_message(msg)
          @mutex.synchronize do
            @pending_requests.delete(req_id)
            @responses.delete(req_id)
          end
          raise RequestError.new(:transport_failure, @reader_failure || "LSP request write failed")
        end
        wait_for_response(req_id, timeout: timeout)
      end

      def wait_for_response(req_id, timeout: 5)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        timed_out = false
        reader_failure = nil

        @mutex.synchronize do
          loop do
            if @responses.key?(req_id)
              response = @responses.delete(req_id)
              @pending_requests.delete(req_id)
              if response.key?("error")
                error = response["error"] || {}
                raise RequestError.new(:server_error, error["message"] || "LSP server returned an error")
              end
              return response["result"] if response.key?("result")

              raise RequestError.new(:invalid_response, "LSP response did not contain a result")
            end

            if @reader_failure
              reader_failure = @reader_failure
              @responses.delete(req_id)
              @pending_requests.delete(req_id)
              break
            end

            remaining = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
            if remaining <= 0
              @responses.delete(req_id)
              @pending_requests.delete(req_id)
              timed_out = true
              break
            end

            @cv.wait(@mutex, remaining)
          end
        end

        if timed_out
          # W9: send $/cancelRequest notification (safely ignored if unsupported)
          begin
            send_notification("$/cancelRequest", { id: req_id })
          rescue StandardError
            nil
          end
          raise RequestError.new(:timeout, "LSP request timed out after #{timeout} seconds")
        end

        raise RequestError.new(:reader_failure, reader_failure) if reader_failure

        nil
      end

      def send_notification(method, params)
        msg = {
          jsonrpc: "2.0",
          method: method,
          params: params
        }
        write_message(msg)
      end

      def write_message(msg_hash)
        json = JSON.dump(msg_hash)
        header = "Content-Length: #{json.bytesize}\r\n\r\n"
        bytes = header + json
        @write_mutex.synchronize do
          offset = 0
          while offset < bytes.bytesize
            written = @stdin.write(bytes.byteslice(offset, bytes.bytesize - offset))
            raise IOError, "LSP transport made no write progress" unless written&.positive?

            offset += written
          end
          @stdin.flush
        end
        true
      rescue IOError, SystemCallError, NoMethodError => e
        message = "LSP transport write failed: #{e.class}: #{e.message}"
        @mutex.synchronize do
          @reader_failure ||= message
          @running = false
          @crashed = true if @wait_thr
          @cv.broadcast
        end
        false
      end

      # Correlate an incoming response with the pending-request registry.
      # Server-request ids and late responses are discarded here exactly as
      # before the extraction (issue #206).
      def correlate_response(msg)
        req_id = msg["id"]
        @mutex.synchronize do
          # Discard late response if request is neither pending nor already tracked
          if @pending_requests.key?(req_id)
            @responses[req_id] = msg
            @cv.broadcast
          end
          # Prune stale responses if cap reached
          if @responses.size > 100
            oldest_keys = @responses.keys.take(@responses.size - 100)
            oldest_keys.each { |k| @responses.delete(k) }
          end
        end
      end

      def sanitized_spawn_env
        Rubik::Platform.sanitized_spawn_env
      end

      # Starts (or restarts) the framing reader thread. Public because the
      # spawn phase and the test seam both drive it directly.
      def start_reader_thread
        @reader_alive = true
        @reader_thr = Thread.new do
          while (@running || @reader_alive) && @stdout && !@stdout.closed?
            begin
              content_length = nil
              loop do
                header_line = @stdout.gets
                break if header_line.nil?

                stripped = header_line.strip
                break if stripped.empty?

                content_length = stripped.split(":", 2).last.strip.to_i if stripped.downcase.start_with?("content-length:")
              end

              break if content_length.nil?

              body = @stdout.read(content_length)
              break unless body

              begin
                parsed = JSON.parse(body)
                dispatch(parsed)
              rescue StandardError => e
                Rubik::Log.warn(:lsp, "Failed to handle message: #{e.class}: #{e.message}")
              end
            rescue IOError, Errno::EPIPE, Errno::ECONNRESET
              break
            rescue StandardError => e
              Rubik::Log.warn(:lsp, "Reader loop error: #{e.class}: #{e.message}")
              next
            end
          end
        ensure
          @mutex.synchronize do
            @crashed = true if @running
            @reader_alive = false
            @running = false
            @reader_failure ||= "LSP response reader stopped before completing the request"
            @cv.broadcast
          end
        end
      end

      private

      # Responses are correlated inside the transport; every other message
      # (server requests, notifications such as publishDiagnostics) is
      # protocol and goes to the Client via the on_message callback.
      def dispatch(msg)
        if msg.key?("id") && !msg.key?("method")
          correlate_response(msg)
        else
          @on_message.call(msg)
        end
      end
    end
  end
end
