# frozen_string_literal: true

require "json"

module Rubik
  module LLM
    class BaseFormatter
      def self.format_messages(messages)
        new.format_messages(messages)
      end

      def self.format_tools(tools)
        new.format_tools(tools)
      end

      # Parse one streaming event into a `Chunk`. The `event` argument is the
      # `{ type:, data: }` Hash produced by `SSEParser` (SSE providers) or
      # `{ raw: <json-string> }` (NDJSON providers). Returns nil to indicate
      # the event should be skipped (e.g. ping, malformed JSON, comment).
      def self.parse_stream_event(event)
        new.parse_stream_event(event)
      end

      def format_messages(messages)
        messages
      end

      def format_tools(tools)
        tools
      end

      # Default: no streaming. Subclasses override.
      def parse_stream_event(_event)
        nil
      end

      protected

      def extract_role(message)
        (message[:role] || message["role"]).to_s
      end

      def extract_content(message)
        message[:content] || message["content"] || ""
      end

      def extract_tool_calls(message)
        message[:tool_calls] || message["tool_calls"]
      end

      def extract_call_id(item, default = "call_default")
        (item[:tool_call_id] || item["tool_call_id"] || item[:call_id] || item["call_id"] || item[:id] || item["id"] || default).to_s
      end
    end

    class OpenAIFormatter < BaseFormatter
      def format_messages(messages)
        return [] if messages.nil?

        formatted = []
        messages.each_with_index do |m, idx|
          role = extract_role(m)
          content = extract_content(m)
          tcs = extract_tool_calls(m)

          if role == "assistant" && tcs
            formatted_tcs = tcs.map do |tc|
              fn_args = tc["args"] || tc[:args] || {}
              args_str = fn_args.is_a?(String) ? fn_args : JSON.generate(fn_args)
              call_id = extract_call_id(tc, "call_#{rand(1000..9999)}")
              {
                "id" => call_id,
                "type" => "function",
                "function" => {
                  "name" => tc["tool"] || tc[:tool],
                  "arguments" => args_str
                }
              }
            end
            msg = { "role" => "assistant", "tool_calls" => formatted_tcs }
            msg["content"] = content if content && !content.empty?
            formatted << msg
          elsif role == "tool"
            call_id = extract_call_id(m, "call_default")
            formatted << {
              "role" => "tool",
              "tool_call_id" => call_id,
              "content" => content
            }
          elsif role == "system"
            if idx == 0
              formatted << { "role" => "system", "content" => content }
            else
              # Strict endpoints like DeepSeek/Groq reject mid-conversation system messages.
              formatted << { "role" => "user", "content" => "[System Notification]\n#{content}" }
            end
          else
            formatted << {
              "role" => role,
              "content" => content
            }
          end
        end
        formatted
      end

      def format_tools(tools)
        return [] if tools.nil?

        tools.map do |tool|
          if tool.key?(:function) || tool.key?("function")
            tool
          else
            fn_name = tool[:name] || tool["name"]
            fn_desc = tool[:description] || tool["description"]
            fn_params = tool[:params_schema] || tool["params_schema"] || tool[:parameters] || tool["parameters"] || { type: "object", properties: {} }

            {
              type: "function",
              function: {
                name: fn_name,
                description: fn_desc,
                parameters: fn_params
              }
            }
          end
        end
      end

      # OpenAI SSE streaming event → Chunk.
      # OpenAI emits `data: {json}` lines for each delta and a
      # terminator `data: [DONE]` line. Each event Hash has
      # { type: "message", data: <json or "[DONE]"> }.
      def parse_stream_event(event)
        data = event[:data].to_s
        return nil if data.empty?
        return Chunk.new(done: true) if data.strip == "[DONE]"

        parsed = JSON.parse(data)
        choices = parsed["choices"] || []
        return nil if choices.empty?

        choice = choices[0] || {}
        delta = choice["delta"] || {}
        text = (delta["content"] && !delta["content"].to_s.empty?) ? delta["content"].to_s : nil

        tool_deltas = nil
        if delta["tool_calls"] && !delta["tool_calls"].empty?
          tool_deltas = delta["tool_calls"].map do |tc|
            {
              "index" => tc["index"],
              "id" => tc["id"],
              "name" => tc.dig("function", "name"),
              "arguments_delta" => tc.dig("function", "arguments").to_s
            }
          end
        end

        usage = nil
        done = false
        if parsed["usage"].is_a?(Hash)
          u = parsed["usage"].dup
          u[:input_tokens] = u.delete("prompt_tokens") || u[:input_tokens] || 0
          u[:output_tokens] = u.delete("completion_tokens") || u[:output_tokens] || 0
          usage = u
          done = true
        end
        done = true if choice["finish_reason"]

        Chunk.new(
          text_delta: text,
          tool_use_delta: tool_deltas,
          usage: usage,
          done: done,
          raw: parsed
        )
      rescue JSON::ParserError
        nil
      end
    end

    class AnthropicFormatter < BaseFormatter
      def format_messages(messages)
        return [] if messages.nil?

        messages.map do |m|
          role = extract_role(m)
          content = extract_content(m)
          tcs = extract_tool_calls(m)

          if role == "assistant" && tcs
            content_blocks = []
            content_blocks << { "type" => "text", "text" => content } if content && !content.empty?
            (tcs || []).each do |tc|
              call_id = extract_call_id(tc, "call_#{rand(1000..9999)}")
              content_blocks << {
                "type" => "tool_use",
                "id" => call_id,
                "name" => tc["tool"] || tc[:tool],
                "input" => tc["args"] || tc[:args] || {}
              }
            end
            { "role" => "assistant", "content" => content_blocks }
          elsif role == "tool"
            call_id = extract_call_id(m, "call_default")
            {
              "role" => "user",
              "content" => [
                {
                  "type" => "tool_result",
                  "tool_use_id" => call_id,
                  "content" => content
                }
              ]
            }
          else
            {
              "role" => role,
              "content" => content
            }
          end
        end
      end

      def format_tools(tools)
        return [] if tools.nil?

        tools.map do |tool|
          if tool.key?(:input_schema) || tool.key?("input_schema")
            tool
          else
            fn = tool[:function] || tool["function"]
            name = fn ? (fn[:name] || fn["name"]) : (tool[:name] || tool["name"])
            desc = fn ? (fn[:description] || fn["description"]) : (tool[:description] || tool["description"])
            schema = fn ? (fn[:parameters] || fn["parameters"]) : (tool[:params_schema] || tool["params_schema"] || tool[:parameters] || tool["parameters"] || {})
            {
              name: name,
              description: desc,
              input_schema: schema
            }
          end
        end
      end

      # Anthropic SSE streaming event → Chunk.
      # Event types: message_start, content_block_start, content_block_delta,
      # content_block_stop, message_delta, message_stop, ping, error
      def parse_stream_event(event)
        type = event[:type].to_s
        data = event[:data].to_s
        return nil if type == "ping"

        if type == "error"
          parsed_err = JSON.parse(data) rescue { "error" => { "message" => data } }
          msg = parsed_err.dig("error", "message") || parsed_err["message"] || "Anthropic streaming error"
          raise ClientError, msg
        end

        parsed = JSON.parse(data)
        chunk = nil

        case type
        when "content_block_delta"
          delta = parsed["delta"] || {}
          if delta["type"] == "text_delta" && delta["text"]
            chunk = Chunk.new(text_delta: delta["text"].to_s)
          elsif delta["type"] == "input_json_delta"
            chunk = Chunk.new(
              tool_use_delta: {
                "index" => parsed["index"],
                "arguments_delta" => delta["partial_json"].to_s
              }
            )
          end
        when "message_delta"
          usage = parsed["usage"] || parsed.dig("delta", "usage")
          chunk = Chunk.new(usage: usage, raw: parsed)
        when "message_stop"
          chunk = Chunk.new(done: true, raw: parsed)
        when "message_start", "content_block_start", "content_block_stop"
          chunk = Chunk.new(raw: parsed)
        end

        chunk || Chunk.new(raw: parsed)
      rescue JSON::ParserError
        nil
      end
    end

    class OllamaFormatter < BaseFormatter
      def format_messages(messages)
        return [] if messages.nil?

        messages.map do |m|
          role = extract_role(m)
          content = extract_content(m)
          tcs = extract_tool_calls(m)

          if role == "tool"
            {
              "role" => "user",
              "content" => content
            }
          elsif role == "assistant" && tcs
            formatted_tcs = tcs.map do |tc|
              fn_args = tc["args"] || tc[:args] || {}
              {
                "function" => {
                  "name" => tc["tool"] || tc[:tool],
                  "arguments" => fn_args
                }
              }
            end
            msg = { "role" => "assistant", "tool_calls" => formatted_tcs }
            msg["content"] = content if content && !content.empty?
            msg
          else
            {
              "role" => role,
              "content" => content
            }
          end
        end
      end

      def format_tools(tools)
        return [] if tools.nil?

        tools.map do |tool|
          if tool.key?(:function) || tool.key?("function")
            tool
          else
            {
              type: "function",
              function: {
                name: tool[:name] || tool["name"],
                description: tool[:description] || tool["description"],
                parameters: tool[:params_schema] || tool["params_schema"] || tool[:parameters] || tool["parameters"]
              }
            }
          end
        end
      end

      # Ollama NDJSON streaming line → Chunk.
      # Each line is a complete JSON object with shape:
      #   { "model": "...", "response": "<text delta>", "done": false }
      # The final line has "done": true plus eval_count / prompt_eval_count.
      def parse_stream_event(event)
        data = event[:data].to_s
        return nil if data.empty?

        parsed = JSON.parse(data)
        text = parsed["response"] unless parsed["response"].to_s.empty?
        done = parsed["done"] == true
        usage = nil
        if done
          usage = {
            input_tokens: parsed["prompt_eval_count"] || 0,
            output_tokens: parsed["eval_count"] || 0
          }
        end
        Chunk.new(
          text_delta: text,
          usage: usage,
          done: done,
          raw: parsed
        )
      rescue JSON::ParserError
        nil
      end
    end
  end
end
