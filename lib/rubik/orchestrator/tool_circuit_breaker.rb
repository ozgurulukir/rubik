# frozen_string_literal: true

require "monitor"

# Opt-in failure isolation for tool execution (G19): after `threshold`
# consecutive failures of the same tool, short-circuit further calls for a
# cooldown instead of burning agent steps on a wedged backend. Disabled by
# default — synchronous execution is the agent loop's design; this only
# stops repeated futile calls once the operator turns it on.
module Rubik
  module Orchestrator
    class ToolCircuitBreaker
      # Raised by the StepExecutor when a call is refused; the executor's
      # normal rescue converts it into a failed tool result so the loop
      # plumbing (events, history) is reused untouched.
      class CircuitOpenError < StandardError; end

      STATES = [:closed, :open, :half_open].freeze

      def initialize(threshold: 5, cooldown_seconds: 60.0)
        @threshold = threshold
        @cooldown_seconds = cooldown_seconds.to_f
        @monitor = Monitor.new
        @tools = {} # name -> { failures:, opened_at:, probing: }
      end

      def state(tool_name)
        @monitor.synchronize { circuit(tool_name)[:state] }
      end

      def allow?(tool_name)
        @monitor.synchronize do
          circuit = circuit(tool_name)
          case circuit[:state]
          when :open
            return false unless cooldown_elapsed?(circuit)

            # one probe through the half-open gate (grant probe call, consume token)
            circuit[:state] = :half_open
            circuit[:probing] = false
            true
          when :half_open
            if circuit[:probing]
              circuit[:probing] = false
              true
            else
              false
            end
          else
            true
          end
        end
      end

      def record_success(tool_name)
        @monitor.synchronize do
          @tools.delete(tool_name)
        end
      end

      def record_failure(tool_name)
        @monitor.synchronize do
          circuit = circuit(tool_name)
          if circuit[:state] == :half_open
            # probe failed: reopen for another full cooldown
            circuit[:opened_at] = now
            circuit[:probing] = false
            circuit[:state] = :open
          else
            circuit[:failures] += 1
            circuit[:state] = :open if circuit[:failures] >= @threshold
            circuit[:opened_at] = now if circuit[:state] == :open && circuit[:opened_at].nil?
          end
        end
      end

      private

      def circuit(tool_name)
        @tools[tool_name] ||= { failures: 0, opened_at: nil, probing: false, state: :closed }
      end

      def cooldown_elapsed?(circuit)
        circuit[:opened_at] && (now - circuit[:opened_at]) >= @cooldown_seconds
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
