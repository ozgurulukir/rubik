# frozen_string_literal: true

module Rubik
  module Platform
    # Continuously drains a child-process IO (stderr) so a chatty child
    # never fills the OS pipe buffer (~64KB) and deadlocks writing
    # diagnostics while the parent waits on stdout. Discards content; the
    # optional on_line observer is a future debug-forwarding hook.
    # Lifecycle contract mirrors the existing reader threads (MCP stdio,
    # LSP stdout): kill + bounded join, never raises from #stop.
    class IoDrain
      JOIN_TIMEOUT = 0.5

      def self.start(io, on_line: nil)
        new(io, on_line: on_line).tap(&:start)
      end

      def initialize(io, on_line: nil)
        @io = io
        @on_line = on_line
        @thread = nil
        @stopped = false
      end

      def start
        @stopped = false
        @thread = Thread.new do
          while (line = @io.gets)
            @on_line&.call(line)
          end
        rescue IOError, Errno::EBADF, Errno::EPIPE => e
          # Expected while #stop closes the pipes underneath us. Any other
          # time it is the watchdog dying while the child may still flood
          # the pipe — the exact deadlock this class exists to prevent —
          # so it must leave a trace.
          warn "[rubik] stderr drain died unexpectedly (#{e.class}: #{e.message})" unless @stopped
        end
        self
      end

      def stop
        @stopped = true
        thread = @thread
        @thread = nil
        return unless thread

        thread.kill
        thread.join(JOIN_TIMEOUT)
        nil
      end
    end
  end
end
