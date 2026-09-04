# frozen_string_literal: true

module Rubik
  module LLM
    # Assembles a final Response from accumulated stream Chunks (Plan 61
    # D-4). Single source of truth shared by Orchestrator::StreamManager
    # (live agent loop) and BaseProvider#complete (batch fallback for
    # stream-only providers), so both paths produce identical text,
    # tool_calls and usage — provider-agnostic assembly is the invariant.
    #
    # Optional callbacks:
    #   estimate_history::  ->( ) { Integer }   input-token fallback (loop history estimate)
    #   estimate_text::     ->(text) { Integer } output-token fallback (provider estimator)
    #   on_malformed_args:: ->(tool_name, fragment) — D-10 diagnostics for
    #   tool-call arguments that arrived truncated/unparseable; the call
    #   still executes with {} args so the model sees the tool's complaint.
    module ChunkAssembler
      module_function

      def build(chunks, streamed: false, estimate_history: nil, estimate_text: nil, on_malformed_args: nil)
        text = chunks.map(&:text_delta).compact.join
        thought_parts = chunks.select { |c| c.respond_to?(:reasoning_delta?) && c.reasoning_delta? }.map(&:reasoning_delta).compact
        thought = thought_parts.empty? ? nil : thought_parts.join
        thought = nil if thought.to_s.empty?

        tool_calls_map = {}
        chunks.each do |chunk|
          deltas = chunk.tool_use_delta
          next if deltas.nil?

          deltas_array = deltas.is_a?(Array) ? deltas : [deltas]
          deltas_array.each do |d|
            next unless d.is_a?(Hash)

            idx = d["index"] || d[:index] || 0
            tool_calls_map[idx] ||= { "id" => nil, "tool" => nil, "args_json" => "", "args" => nil }

            tool_calls_map[idx]["id"] ||= d["id"] || d[:id]
            tool_calls_map[idx]["tool"] ||= d["name"] || d[:name] || d["tool"] || d[:tool]
            tool_calls_map[idx]["args_json"] += (d["arguments_delta"] || d[:arguments_delta]).to_s if d["arguments_delta"] || d[:arguments_delta]
            tool_calls_map[idx]["args"] = d["args"] || d[:args] if d["args"] || d[:args]
          end
        end

        chunks.each do |chunk| # rubocop:disable Style/CombinableLoops -- akış işleme aşamaları ayrı döngülerde kalmalı; birleştirim olay sırasını değiştirir
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

          next unless raw["message"] && raw["message"]["tool_calls"].is_a?(Array)

          raw["message"]["tool_calls"].each_with_index do |tc, idx|
            fn = tc["function"] || {}
            tool_calls_map[idx] ||= { "id" => tc["id"], "tool" => fn["name"], "args" => fn["arguments"], "args_json" => "" }
          end
        end

        parsed_tool_calls = tool_calls_map.values.map do |tc_data|
          args = tc_data["args"]
          if args.nil?
            args_str = tc_data["args_json"].strip
            if args_str.empty?
              args = {}
            else
              begin
                parsed = JSON.parse(args_str)
                args = parsed.is_a?(Hash) ? parsed : {}
              rescue StandardError
                on_malformed_args&.call(tc_data["tool"], args_str)
                args = {}
              end
            end
          elsif args.is_a?(String)
            begin
              parsed = JSON.parse(args)
              args = parsed.is_a?(Hash) ? parsed : {}
            rescue StandardError
              on_malformed_args&.call(tc_data["tool"], args)
              args = {}
            end
          elsif !args.is_a?(Hash)
            args = {}
          end

          {
            "id" => tc_data["id"] || "call_#{rand(1000..9999)}",
            "tool" => tc_data["tool"],
            "args" => args || {}
          }
        end
        parsed_tool_calls.reject! { |tc| tc["tool"].nil? || tc["tool"].to_s.empty? }

        final_usage = resolve_usage(chunks, text, estimate_history, estimate_text)

        last_raw = chunks.reverse.find { |c| c.raw && !c.raw.empty? }&.raw || {}
        raw_with_finish = chunks.reverse.find do |c|
          c.raw.is_a?(Hash) && extract_finish_value(c.raw)
        end
        if raw_with_finish && !extract_finish_value(last_raw)
          last_raw = last_raw.dup
          finish_val = raw_with_finish.raw["finish_reason"] || raw_with_finish.raw.dig("choices", 0, "finish_reason")
          last_raw["finish_reason"] = finish_val if finish_val
          stop_val = raw_with_finish.raw["stop_reason"] || raw_with_finish.raw.dig("delta", "stop_reason")
          last_raw["stop_reason"] = stop_val if stop_val
          last_raw["done_reason"] = raw_with_finish.raw["done_reason"] if raw_with_finish.raw["done_reason"]
        end

        Rubik::LLM::Response.new(
          text: text,
          usage: final_usage,
          raw: last_raw,
          tool_calls: parsed_tool_calls,
          streamed: streamed == true,
          thought: thought
        )
      end

      def resolve_usage(chunks, text, estimate_history, estimate_text)
        usage_found = chunks.reverse.find { |c| c.usage && !c.usage.empty? }&.usage
        in_tokens = usage_found && (usage_found[:input_tokens] || usage_found["input_tokens"])
        out_tokens = usage_found && (usage_found[:output_tokens] || usage_found["output_tokens"])

        in_tokens ||= estimate_history.respond_to?(:call) ? estimate_history.call : nil
        out_tokens = estimate_text.call(text) || (text.length / 4.0).ceil if out_tokens.nil? && estimate_text.respond_to?(:call)

        if in_tokens || out_tokens
          { input_tokens: in_tokens || 0, output_tokens: out_tokens || 0 }
        else
          {}
        end
      end

      def extract_finish_value(raw)
        return nil unless raw.is_a?(Hash)

        raw["finish_reason"] || raw.dig("choices", 0, "finish_reason") ||
          raw["stop_reason"] || raw.dig("delta", "stop_reason") || raw["done_reason"]
      end
    end
  end
end
