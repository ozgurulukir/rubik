# frozen_string_literal: true

require_relative "../llm/chunk_assembler"
require_relative "provider_recovery"

module Rubik
  module Orchestrator
    # Streaming request execution and chunk-to-response assembly (Plan 54
    # D-6). Stateless collaborator over Loop-held state. Overflow recovery
    # (retry-once after emergency compaction; Interrupt, not being a
    # StandardError, escapes to the shell's console restoration) lives in
    # ProviderRecovery — this class keeps the chunk pipeline and keeps ALL
    # per-attempt state inside the recovered block.
    class StreamManager
      # Plan 87 E-1: state is reached through the ShellDeps façade. Accepts a
      # bare loop for compatibility with existing test doubles (wrapped).
      def initialize(loop_or_deps)
        @deps = ShellDeps.wrap(loop_or_deps)
      end

      def execute_streaming_request(opts)
        # Recovery policy lives in ProviderRecovery; the block owns ALL
        # per-attempt state. `retry` re-yields the block, so a failed
        # attempt's accumulated chunks can never pollute the retried
        # response (the Candidate 03 fix). The config guard mirrors
        # #process_stream_chunk: bare test doubles may not expose config.
        ProviderRecovery.with_recovery(
          config: @deps.respond_to?(:config) ? @deps.config : nil,
          compact: ->(reason) { @deps.emergency_compact_and_notify!(reason) }
        ) do
          accumulated_chunks = []
          streamed_text = false
          res = @deps.provider.stream_chat(@deps.history, opts) do |chunk|
            accumulated_chunks << chunk
            streamed_text = true if process_stream_chunk(chunk)
          end

          if res.is_a?(Enumerator) && accumulated_chunks.empty?
            res.each do |chunk|
              accumulated_chunks << chunk
              streamed_text = true if process_stream_chunk(chunk)
            end
          end

          @deps.on_step&.call(type: :chunk_end, step: @deps.step_count, max_steps: @deps.max_steps) if streamed_text
          @deps.mark_last_turn_streamed!(streamed_text)
          build_response_from_chunks(accumulated_chunks, streamed_text: streamed_text)
        end
      end

      def build_response_from_chunks(accumulated_chunks, streamed_text: false)
        # Plan 61 D-4: assembly moved to Rubik::LLM::ChunkAssembler (shared
        # with BaseProvider#complete); this delegate keeps the historical
        # call signature for tests and any external consumers.
        Rubik::LLM::ChunkAssembler.build(
          accumulated_chunks,
          streamed: streamed_text == true,
          estimate_history: -> { @deps.budget_manager.estimate_tokens_from_history },
          estimate_text: ->(t) { @deps.provider.respond_to?(:estimate_tokens) ? @deps.provider.estimate_tokens(t) : nil },
          on_malformed_args: lambda { |tool_name, fragment|
            @deps.on_step&.call(
              type: :malformed_tool_args, tool: tool_name,
              fragment: fragment.to_s[0, 200],
              step: @deps.step_count, max_steps: @deps.max_steps
            )
          }
        )
      end

      # Forwards HTTPClient retry notifications to the shell's on_step channel
      # as :llm_retry step_info so the REPL prints live retry lines instead of
      # appearing frozen. Custom providers that ignore opts[:on_retry] simply
      # produce no retry output. Loop state is read at invocation time.
      def llm_retry_notifier
        lambda do |attempt, max, reason|
          @deps.on_step&.call(type: :llm_retry, attempt: attempt, max: max, reason: reason,
                              step: @deps.step_count, max_steps: @deps.max_steps)
        end
      end

      private

      # One chunk, both delivery forms (stream block + Enumerator replay):
      # resolve the reasoning-capture knob, forward deltas as step events,
      # and report whether a text delta was emitted (drives streamed_text
      # and chunk_end).
      def process_stream_chunk(chunk)
        capture_reasoning = if @deps.respond_to?(:safe_config)
                              @deps.safe_config("llm.capture_reasoning", true) != false
                            elsif @deps.respond_to?(:config) && @deps.config.respond_to?(:fetch)
                              @deps.config.fetch("llm.capture_reasoning", true) != false
                            else
                              true
                            end
        if capture_reasoning &&
           chunk.respond_to?(:reasoning_delta?) && chunk.reasoning_delta? && !chunk.reasoning_delta.to_s.empty?
          @deps.on_step&.call(
            type: :llm_thought_delta,
            delta: chunk.reasoning_delta,
            step: @deps.step_count,
            max_steps: @deps.max_steps
          )
        end
        emitted_text = false
        if chunk.text_delta? && !chunk.text_delta.to_s.empty?
          emitted_text = true
          @deps.on_step&.call(
            type: :chunk,
            delta: chunk.text_delta,
            step: @deps.step_count,
            max_steps: @deps.max_steps
          )
        end
        emitted_text
      end
    end
  end
end
