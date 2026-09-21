# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Semaphore gate limiting concurrent outbound LLM requests across subagents (Plan 97).
      # Prevents network queue exhaustion and 90s provider read timeouts under load.
      class ConcurrencyGate
        attr_reader :capacity

        def initialize(capacity = 2)
          @capacity = [capacity.to_i, 1].max
          @queue = Thread::SizedQueue.new(@capacity)
          @capacity.times { @queue.push(:token) }
        end

        def synchronize
          token = @queue.pop
          acquired = true
          begin
            yield
          ensure
            @queue.push(token) if acquired
          end
        end

        def active_count
          @capacity - @queue.size
        end

        def available_count
          @queue.size
        end
      end
    end
  end
end
