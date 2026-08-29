# frozen_string_literal: true

module Rubik
  module LLM
    # Aggregate response from a blocking `#complete` call.
    # Holds the full text, final usage stats, raw provider payload, and any tool calls.
    class Response
      attr_reader :text, :usage, :raw, :tool_calls, :streamed

      def initialize(text:, usage: {}, raw: {}, tool_calls: [], streamed: false)
        @text = text.to_s
        @usage = usage # { input_tokens: int, output_tokens: int }
        @raw = raw
        @tool_calls = tool_calls || []
        @streamed = streamed == true
      end

      def has_tool_calls?
        !@tool_calls.empty?
      end
    end

    # One streaming chunk delivered by `#stream_chat`. A `Chunk` represents
    # either an incremental text delta, a tool-use delta, a final usage summary,
    # or a terminator (`done: true`). Concrete providers normalize provider-
    # specific SSE/NDJSON events into `Chunk`s.
    class Chunk
      attr_reader :text_delta, :tool_use_delta, :usage, :done, :raw

      def initialize(text_delta: nil, tool_use_delta: nil, usage: nil, done: false, raw: {})
        @text_delta = text_delta
        @tool_use_delta = tool_use_delta
        @usage = usage
        @done = done
        @raw = raw
      end

      def text_delta?
        !@text_delta.nil?
      end

      def tool_use_delta?
        !@tool_use_delta.nil?
      end

      def done?
        @done
      end
    end

    class BaseProvider
      # Abstract: concrete providers must implement one of:
      #   - `#stream_chat` (preferred — enables both APIs via the `complete` fallback below)
      #   - `#complete` (legacy blocking-only path)
      def stream_chat(messages, opts = {}, &block)
        if method(:complete).owner != Rubik::LLM::BaseProvider
          res = complete(messages, opts)
          chunk = if res.is_a?(Rubik::LLM::Response)
                    tc_deltas = res.tool_calls.map.with_index do |tc, idx|
                      {
                        "index" => idx,
                        "id" => tc["id"] || tc[:id],
                        "name" => tc["tool"] || tc[:tool] || tc["name"] || tc[:name],
                        "args" => tc["args"] || tc[:args]
                      }
                    end
                    Chunk.new(
                      text_delta: res.text.to_s.empty? ? nil : res.text,
                      tool_use_delta: tc_deltas.empty? ? nil : tc_deltas,
                      usage: res.usage,
                      raw: res.raw,
                      done: true
                    )
                  else
                    Chunk.new(text_delta: res.to_s, done: true)
                  end
          if block
            block.call(chunk)
            res
          else
            [chunk].to_enum
          end
        else
          raise NotImplementedError, "#{self.class} must implement #stream_chat (or #complete)"
        end
      end

      # Default `#complete` implementation: collects chunks from `#stream_chat`
      # and assembles them via ChunkAssembler (Plan 61 D-4). Concrete providers
      # may override for a more efficient batch path, but the streaming
      # implementation alone is sufficient and must keep tool calls intact —
      # a stream-only provider routed through batch mode may not lose them.
      def complete(messages, opts = {})
        chunks = []
        # Re-route through #stream_chat so we never duplicate provider logic.
        result = stream_chat(messages, opts) do |chunk|
          chunks << chunk
        end
        # If the provider returned an Enumerator (no block given), drain it.
        if result.is_a?(Enumerator) && chunks.empty?
          result.each { |chunk| chunks << chunk }
        end
        Rubik::LLM::ChunkAssembler.build(chunks, streamed: false)
      end

      def sanitize_prompt(prompt)
        "<user_input>#{prompt}</user_input>"
      end

      def estimate_tokens(text)
        return 0 if text.nil? || text.to_s.empty?
        (text.to_s.length / 4.0).ceil
      end
    end
  end
end
