# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Deep module (Candidate 03): the ONE home for provider-call recovery
    # policy. Three call sites carried private copies of the same
    # rescue/retry/compact control flow and drifted (a streaming retry that
    # re-used the failed attempt's chunks, a silent subagent compaction,
    # three config-gate spellings). This module owns everything the policy
    # needs and nothing it does not.
    #
    #   owns   : overflow classification, auto-recover gate, retry-once
    #            control flow, compaction-config resolution, request-timeout
    #            defaults
    #   leaves : the provider call itself (the block); which history is
    #            compacted and what observability fires (the compact
    #            callable — each site's emergency_compact_and_notify!)
    #
    # Idiom (load-bearing): keep ALL per-attempt state inside the block.
    # `retry` re-executes the begin, which re-yields, which re-runs the
    # block with fresh block-locals — the structural fix for the streaming
    # chunk-pollution bug. Interrupt is not a StandardError and escapes.
    module ProviderRecovery
      # Provider errors matching this are context-window overflows (OpenAI
      # context_length_exceeded, Anthropic "prompt is too long", generic
      # token-limit wording). Collapsed from the three former inline regexes.
      #
      # NOTE: a bare /context/ alternative is deliberately absent. Go-based
      # provider proxies surface transport failures as "context deadline
      # exceeded" / "context canceled" — those must fail (or retry at the
      # transport layer), never trigger the emergency compaction this gate
      # unwinds into, which is destructive and irreversible.
      OVERFLOW_PATTERN = /context_length|context window|maximum context|prompt is too long|token limit|too many tokens/i

      # Config gate for the automatic compaction+retry (default: on).
      AUTO_RECOVER_KEY = "context.auto_recover_on_overflow"

      # Config section every compaction call site resolves.
      COMPACTION_CONFIG_KEY = "context"

      # Named request-timeout defaults. Per-site values preserved on
      # purpose: a subagent step is a short focused call; the shell's
      # streaming turn may legitimately think longer.
      DEFAULT_OPEN_TIMEOUT = 15
      SUBAGENT_REQUEST_TIMEOUT = 90
      STREAM_REQUEST_TIMEOUT = 120

      module_function

      # Executes the provider call with context-overflow recovery. On the
      # first overflow-classified StandardError: run the site's compact
      # callable (reason = the provider's error message), then retry the
      # block exactly once. Everything else re-raises untouched, including
      # Interrupt (not a StandardError) and errors raised by compact itself
      # (fail loud — half-recovered state must surface, never be swallowed).
      def with_recovery(config:, compact:)
        retry_attempted = false
        begin
          yield
        rescue StandardError => e
          raise e unless !retry_attempted && auto_recover?(config) && overflow_error?(e)

          retry_attempted = true
          compact.call(e.message)
          retry
        end
      end

      # Defensive resolution of the "context" config section shared by every
      # compaction call site: nil config, fetch-less objects, and null YAML
      # sections all collapse to {}. One spelling replaces five.
      def compaction_config(config)
        cfg = config.respond_to?(:fetch) ? config.fetch(COMPACTION_CONFIG_KEY, {}) : {}
        cfg.is_a?(Hash) ? cfg : {}
      end

      # ── implementation details (not interface) ────────────────────────

      def auto_recover?(config)
        config.respond_to?(:fetch) ? config.fetch(AUTO_RECOVER_KEY, true) : true
      end

      def overflow_error?(err)
        err.message.to_s.match?(OVERFLOW_PATTERN)
      end

      private_class_method :auto_recover?, :overflow_error?
    end
  end
end
