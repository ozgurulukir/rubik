# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Streaming request execution and chunk-to-response assembly (Plan 54
    # D-6). Stateless collaborator over Loop-held state. Two contracts must
    # survive verbatim: the rescue clauses must NOT catch Interrupt (it is not
    # a StandardError; Ctrl+C has to escape through to the shell's console
    # restoration), and the bare `retry` must re-execute the whole begin
    # block — including a fresh provider call — after emergency compaction.
    class StreamManager
      def initialize(loop)
        @loop = loop
      end

      def execute_streaming_request(opts)
        accumulated_chunks = []
        streamed_text = false
        retry_attempted = false

        begin
          res = @loop.provider.stream_chat(@loop.history, opts) do |chunk|
            accumulated_chunks << chunk
            if chunk.text_delta? && !chunk.text_delta.to_s.empty?
              streamed_text = true
              @loop.on_step&.call(
                type: :chunk,
                delta: chunk.text_delta,
                step: @loop.step_count,
                max_steps: @loop.max_steps
              )
            end
          end

          if res.is_a?(Enumerator) && accumulated_chunks.empty?
            res.each do |chunk|
              accumulated_chunks << chunk
              if chunk.text_delta? && !chunk.text_delta.to_s.empty?
                streamed_text = true
                @loop.on_step&.call(
                  type: :chunk,
                  delta: chunk.text_delta,
                  step: @loop.step_count,
                  max_steps: @loop.max_steps
                )
              end
            end
          end

          @loop.on_step&.call(type: :chunk_end, step: @loop.step_count, max_steps: @loop.max_steps) if streamed_text
          @loop.last_turn_streamed = streamed_text
          build_response_from_chunks(accumulated_chunks, streamed_text: streamed_text)
        rescue Rubik::LLM::ClientError, StandardError => e
          auto_recover = @loop.config ? @loop.config.fetch("context.auto_recover_on_overflow", true) : true
          if !retry_attempted && auto_recover && e.message =~ /context|context_length|maximum context|prompt is too long|token limit|too many tokens/i
            retry_attempted = true
            Rubik::Prompt::EmergencyCompactor.compact!(@loop.history)
            @loop.on_step&.call(type: :emergency_compact, reason: e.message, step: @loop.step_count, max_steps: @loop.max_steps)
            retry
          else
            raise e
          end
        end
      end

      def build_response_from_chunks(accumulated_chunks, streamed_text: false)
        text = accumulated_chunks.map(&:text_delta).compact.join

        tool_calls_map = {}
        accumulated_chunks.each do |chunk|
          deltas = chunk.tool_use_delta
          next if deltas.nil?

          deltas_array = deltas.is_a?(Array) ? deltas : [deltas]
          deltas_array.each do |d|
            next unless d.is_a?(Hash)

            idx = d["index"] || d[:index] || 0
            tool_calls_map[idx] ||= { "id" => nil, "tool" => nil, "args_json" => "", "args" => nil }

            tool_calls_map[idx]["id"] ||= d["id"] || d[:id]
            tool_calls_map[idx]["tool"] ||= d["name"] || d[:name] || d["tool"] || d[:tool]
            if d["arguments_delta"] || d[:arguments_delta]
              tool_calls_map[idx]["args_json"] += (d["arguments_delta"] || d[:arguments_delta]).to_s
            end
            if d["args"] || d[:args]
              tool_calls_map[idx]["args"] = d["args"] || d[:args]
            end
          end
        end

        accumulated_chunks.each do |chunk|
          raw = chunk.raw
          next unless raw.is_a?(Hash)

          if raw["type"] == "content_block_start" && raw["content_block"].is_a?(Hash)
            cb = raw["content_block"]
            if cb["type"] == "tool_use"
              idx = raw["index"] || 0
              tool_calls_map[idx] ||= { "id" => nil, "tool" => nil, "args_json" => "", "args" => nil }
              tool_calls_map[idx]["id"] ||= cb["id"]
              tool_calls_map[idx]["tool"] ||= cb["name"]
            end
          end

          if raw["message"] && raw["message"]["tool_calls"].is_a?(Array)
            raw["message"]["tool_calls"].each_with_index do |tc, idx|
              fn = tc["function"] || {}
              tool_calls_map[idx] ||= { "id" => tc["id"], "tool" => fn["name"], "args" => fn["arguments"], "args_json" => "" }
            end
          end
        end

        parsed_tool_calls = tool_calls_map.values.map do |tc_data|
          args = tc_data["args"]
          if args.nil?
            args_str = tc_data["args_json"].strip
            args = if args_str.empty?
                     {}
                   else
                     begin
                       parsed = JSON.parse(args_str)
                       parsed.is_a?(Hash) ? parsed : {}
                     rescue StandardError
                       {}
                     end
                   end
          elsif args.is_a?(String)
            parsed = (JSON.parse(args) rescue {})
            args = parsed.is_a?(Hash) ? parsed : {}
          elsif !args.is_a?(Hash)
            args = {}
          end

          {
            "id" => tc_data["id"] || "call_#{rand(1000..9999)}",
            "tool" => tc_data["tool"],
            "args" => args || {}
          }
        end.reject { |tc| tc["tool"].nil? || tc["tool"].to_s.empty? }

        final_chunk_with_usage = accumulated_chunks.reverse.find { |c| c.usage && !c.usage.empty? }
        usage = final_chunk_with_usage&.usage || {}
        in_tokens = usage[:input_tokens] || usage["input_tokens"] || usage["prompt_tokens"] ||
                    @loop.budget_manager.estimate_tokens_from_history
        out_tokens = usage[:output_tokens] || usage["output_tokens"] || usage["completion_tokens"] ||
                     (@loop.provider.respond_to?(:estimate_tokens) ? @loop.provider.estimate_tokens(text) : (text.length / 4.0).ceil)
        final_usage = { input_tokens: in_tokens, output_tokens: out_tokens }

        last_raw = accumulated_chunks.reverse.find { |c| c.raw && !c.raw.empty? }&.raw || {}

        Rubik::LLM::Response.new(
          text: text,
          usage: final_usage,
          raw: last_raw,
          tool_calls: parsed_tool_calls,
          streamed: streamed_text == true
        )
      end

      # Forwards HTTPClient retry notifications to the shell's on_step channel
      # as :llm_retry step_info so the REPL prints live retry lines instead of
      # appearing frozen. Custom providers that ignore opts[:on_retry] simply
      # produce no retry output. Loop state is read at invocation time.
      def llm_retry_notifier
        ->(attempt, max, reason) do
          @loop.on_step&.call(type: :llm_retry, attempt: attempt, max: max, reason: reason,
                              step: @loop.step_count, max_steps: @loop.max_steps)
        end
      end
    end
  end
end
