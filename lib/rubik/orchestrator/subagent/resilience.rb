# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Transient network/provider error detection, backoff retries, and
      # pause-on-error coordination for autonomous subagents (Plan 101).
      module Resilience
        DEFAULT_NETWORK_RETRIES = 3
        DEFAULT_BACKOFF_BASE = 0.5
        DEFAULT_ERROR_WAIT_TIMEOUT = 300

        TRANSIENT_PATTERN = Regexp.union(
          /5\d{2}|server_error|engine[-_]core error|rate[-_]limit|too many requests/i,
          /read timeout|timeout|closed stream|closed socket/i,
          /connection reset|connection refused|broken pipe/i
        )

        module_function

        def transient_error?(err)
          return false unless err.is_a?(StandardError)

          msg = err.message.to_s
          return true if msg.match?(TRANSIENT_PATTERN)
          return true if defined?(Rubik::LLM::RateLimitError) && err.is_a?(Rubik::LLM::RateLimitError)
          return true if defined?(Rubik::LLM::ClientError) && err.is_a?(Rubik::LLM::ClientError) && msg.match?(TRANSIENT_PATTERN)

          transient_exception_class?(err)
        end

        def transient_exception_class?(err)
          name = err.class.name.to_s
          name.include?("Timeout") ||
            name.include?("Socket") ||
            name.include?("ECONNRESET") ||
            name.include?("ECONNREFUSED") ||
            name.include?("EPIPE") ||
            name.include?("EOFError")
        end

        def retry_transient(config: nil, gate: nil, max_retries: nil, backoff_base: nil, on_retry: nil, &block)
          retries_limit = max_retries ||
                          (config.respond_to?(:fetch) && config.fetch("subagents.network_retry_count", nil)) ||
                          DEFAULT_NETWORK_RETRIES
          base_delay = backoff_base ||
                       (config.respond_to?(:fetch) && config.fetch("subagents.network_backoff_base", nil)) ||
                       DEFAULT_BACKOFF_BASE

          attempt = 0
          begin
            attempt += 1
            if gate
              gate.synchronize(&block)
            else
              block.call
            end
          rescue StandardError => e
            raise e unless attempt <= retries_limit.to_i && transient_error?(e)

            delay = base_delay.to_f * (2**(attempt - 1)) * (0.8 + (0.4 * rand))
            on_retry&.call(attempt, retries_limit.to_i, delay, e)
            sleep(delay)
            retry
          end
        end
      end
    end
  end
end
