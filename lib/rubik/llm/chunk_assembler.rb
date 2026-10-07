# frozen_string_literal: true

# Red-team: JSON.parse is used in the args paths; without this require a
# standalone load (or any load order where json is not yet loaded) turns
# every parse into a NameError that the StandardError rescue silently
# converts to empty args — tool arguments vanish without a trace.
require "json"

require_relative "provider"

module Rubik
  module LLM
    class Chunk
      # Incremental, single-pass assembler (Plan 87 E-2, carrying Plan 86
      # D-1): each pushed chunk updates O(1) accumulators — text/thought
      # buffers, tool-call slots, last-writer-wins usage/raw/finish state —
      # so batch callers never buffer the chunk list. #finish produces the
      # exact Response the multi-pass ChunkAssembler.build produces; the
      # equivalence is pinned by the golden snapshots and the build ↔
      # incremental equivalence test in test_chunk_assembler.rb.
      #
      # Known accepted divergence (same class as Red-team B3): build runs
      # the tool_use_delta pass over ALL chunks before the raw pass, while
      # push interleaves both per chunk. For same-index tool calls arriving
      # as one raw message and one delta with DIFFERENT ids, the resulting
      # slot order may differ; runtime matching is by call id, not order.
      class Assembler
        def initialize
          @text = +""
          @thought = +""
          @tool_calls_map = {}
          @last_usage = nil
          @last_raw = nil
          @finish_raw = nil
          @pushed = false
        end

        # Whether any chunk reached the assembler (used by #complete to
        # decide the Enumerator drain fallback).
        def pushed?
          @pushed
        end

        def push(chunk)
          @pushed = true
          @text << chunk.text_delta.to_s unless chunk.text_delta.nil?
          @thought << chunk.reasoning_delta.to_s if chunk.respond_to?(:reasoning_delta?) && chunk.reasoning_delta? && !chunk.reasoning_delta.nil?

          deltas = chunk.tool_use_delta
          unless deltas.nil?
            deltas_array = deltas.is_a?(Array) ? deltas : [deltas]
            deltas_array.each { |d| process_tool_delta(d) }
          end

          process_raw_tool_calls(chunk.raw) if chunk.raw.is_a?(Hash)

          @last_usage = chunk.usage if chunk.usage && !chunk.usage.empty?
          @last_raw = chunk.raw if chunk.raw && !chunk.raw.empty?
          @finish_raw = chunk.raw if chunk.raw.is_a?(Hash) && extract_finish_value(chunk.raw)
          self
        end

        def finish(streamed: false, estimate_history: nil, estimate_text: nil, on_malformed_args: nil)
          tool_calls, degenerate = parsed_tool_calls_with_degenerate(on_malformed_args)
          @text = append_degenerate_text(degenerate)
          final_usage = resolve_usage(@text, estimate_history, estimate_text)

          Rubik::LLM::Response.new(
            text: @text,
            usage: final_usage,
            raw: promoted_raw,
            tool_calls: tool_calls,
            streamed: streamed == true,
            thought: @thought.empty? ? nil : @thought
          )
        end

        private

        def process_tool_delta(delta)
          return unless delta.is_a?(Hash)

          base_idx = delta["index"] || delta[:index] || 0
          d_id = delta["id"] || delta[:id]
          d_tool = delta["tool"] || delta[:tool] || delta["name"] || delta[:name]

          key = resolve_slot(base_idx, d_id)
          @tool_calls_map[key]["id"] ||= d_id
          @tool_calls_map[key]["tool"] ||= d_tool
          @tool_calls_map[key]["args_json"] += (delta["arguments_delta"] || delta[:arguments_delta]).to_s if delta["arguments_delta"] || delta[:arguments_delta]
          @tool_calls_map[key]["args"] = delta["args"] || delta[:args] if delta["args"] || delta[:args]
        end

        def process_raw_tool_calls(raw)
          if raw["type"] == "content_block_start" && raw["content_block"].is_a?(Hash)
            cb = raw["content_block"]
            if cb["type"] == "tool_use"
              key = resolve_slot(raw["index"] || 0, cb["id"])
              @tool_calls_map[key]["id"] ||= cb["id"]
              @tool_calls_map[key]["tool"] ||= cb["name"]
            end
          end

          return unless raw["message"] && raw["message"]["tool_calls"].is_a?(Array)

          raw["message"]["tool_calls"].each_with_index do |tc, idx|
            fn = tc["function"] || {}
            key = resolve_slot(idx, tc["id"])
            @tool_calls_map[key]["id"] ||= tc["id"]
            @tool_calls_map[key]["tool"] ||= fn["name"]
            @tool_calls_map[key]["args"] ||= fn["arguments"]
          end
        end

        # Red-team B2: üç montaj yolu (tool_use_delta, content_block_start, raw
        # message) aynı slot-çözme mantığını kullansın. Aynı index üzerinde dolu ve
        # farklı bir id görüldüğünde ayrı bir slot açılır: InternLM/lmdeploy ve bazı
        # stream'ler aynı index'i yeni bir logical call için yeniden kullanabilir;
        # katıştırmak arguments'ları karıştırıp bozuk JSON'a yol açar. Boş/nil id bir
        # call'ı tanımlamaz — split'i tetiklemez.
        #
        # Red-team notları (bilinen sınırlar):
        # - B3: `tool_calls_map` insertion-order üretir; interleaved delta sırası
        #   `values` sırasını değiştirebilir. Runtime'da zararsızdır çünkü sonraki
        #   eşleşme call id/tool_call_id üzerindendir, sıra değil.
        # - B4: aynı index üzerinde id'siz iki FARKLI call ayırt edilemez (bilgi
        #   yok). lmdeploy her call'a en az bir id ya da benzersiz index verdiği
        #   sürece oluşmaz.
        # - B5: composite key `"#{base_idx}:#{d_id}"`; d_id içinde ':' olsa bile
        #   farklı key'ler ayrı kalır (çakışma yok, çünkü tam-string eşleşmesi).
        def resolve_slot(base_idx, d_id)
          key = base_idx
          if @tool_calls_map.key?(base_idx) &&
             !d_id.nil? && !d_id.to_s.empty? &&
             !@tool_calls_map[base_idx]["id"].nil? &&
             @tool_calls_map[base_idx]["id"] != d_id
            key = "#{base_idx}:#{d_id}"
          end
          @tool_calls_map[key] ||= { "id" => nil, "tool" => nil, "args_json" => "", "args" => nil }
          key
        end

        def parsed_tool_calls_with_degenerate(on_malformed_args)
          parsed_tool_calls = @tool_calls_map.values.map do |tc_data|
            args = tc_data["args"]
            malformed = nil
            if args.nil?
              args_str = tc_data["args_json"].strip
              if args_str.empty?
                args = {}
              else
                begin
                  parsed = JSON.parse(args_str)
                  if parsed.is_a?(Hash)
                    args = parsed
                  else
                    args = {}
                    malformed = args_str
                  end
                rescue JSON::ParserError
                  on_malformed_args&.call(tc_data["tool"], args_str)
                  args = {}
                  malformed = args_str
                end
              end
            elsif args.is_a?(String)
              begin
                parsed = JSON.parse(args)
                if parsed.is_a?(Hash)
                  args = parsed
                else
                  malformed = args
                  args = {}
                end
              rescue JSON::ParserError
                on_malformed_args&.call(tc_data["tool"], args)
                malformed = args
                args = {}
              end
            elsif !args.is_a?(Hash)
              malformed = args.to_s
              args = {}
            end

            row = {
              "id" => tc_data["id"] || "call_#{rand(1000..9999)}",
              "tool" => tc_data["tool"],
              "args" => args || {}
            }
            # Issue #55 3.4: the executor turns this marker into the
            # model-visible error row quoting the rejected payload — the
            # degrade must not be silent at both layers.
            row["malformed_args"] = malformed if malformed
            row
          end
          # Red-team B1: tool name'siz yarım call'ı sessizce silmek, üretilmiş
          # arguments'ı da yok eder ve (text boşken) "Empty response from model"a
          # yol açabilir. Arguments'ı metne bağlayarak bilgiyi koruyor ve modelin
          # boş olmayan bir yanıt görmesini sağlıyoruz; gerçekten boş call'lar elenir.
          degenerate = []
          parsed_tool_calls = parsed_tool_calls.reject do |tc|
            if tc["tool"].nil? || tc["tool"].to_s.empty?
              args = tc["args"]
              degenerate << args if args.is_a?(Hash) && !args.empty?
              true
            else
              false
            end
          end
          [parsed_tool_calls, degenerate]
        end

        def append_degenerate_text(degenerate)
          return @text if degenerate.empty?

          appended = degenerate.map { |a| "[Incomplete tool call — arguments: #{a.to_json}]" }.join(" ")
          @text.to_s.empty? ? appended : "#{@text}\n#{appended}"
        end

        def resolve_usage(text, estimate_history, estimate_text)
          in_tokens = @last_usage && (@last_usage[:input_tokens] || @last_usage["input_tokens"])
          out_tokens = @last_usage && (@last_usage[:output_tokens] || @last_usage["output_tokens"])

          in_tokens ||= estimate_history.respond_to?(:call) ? estimate_history.call : nil
          out_tokens = estimate_text.call(text) || (text.length / 4.0).ceil if out_tokens.nil? && estimate_text.respond_to?(:call)

          if in_tokens || out_tokens
            { input_tokens: in_tokens || 0, output_tokens: out_tokens || 0 }
          else
            {}
          end
        end

        def promoted_raw
          last_raw = @last_raw || {}
          if @finish_raw && !extract_finish_value(last_raw)
            last_raw = last_raw.dup
            finish_val = @finish_raw["finish_reason"] || @finish_raw.dig("choices", 0, "finish_reason")
            last_raw["finish_reason"] = finish_val if finish_val
            stop_val = @finish_raw["stop_reason"] || @finish_raw.dig("delta", "stop_reason")
            last_raw["stop_reason"] = stop_val if stop_val
            last_raw["done_reason"] = @finish_raw["done_reason"] if @finish_raw["done_reason"]
          end
          last_raw
        end

        def extract_finish_value(raw)
          return nil unless raw.is_a?(Hash)

          raw["finish_reason"] || raw.dig("choices", 0, "finish_reason") ||
            raw["stop_reason"] || raw.dig("delta", "stop_reason") || raw["done_reason"]
        end
      end
    end

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

      # Plan 87 E-2: build feeds the chunk list through the incremental
      # Chunk::Assembler — one assembly logic, two consumption styles.
      def build(chunks, streamed: false, estimate_history: nil, estimate_text: nil, on_malformed_args: nil)
        assembler = Chunk::Assembler.new
        chunks.each { |chunk| assembler.push(chunk) }
        assembler.finish(
          streamed: streamed,
          estimate_history: estimate_history,
          estimate_text: estimate_text,
          on_malformed_args: on_malformed_args
        )
      end
    end
  end
end
