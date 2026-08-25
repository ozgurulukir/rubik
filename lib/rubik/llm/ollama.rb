# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"
require "json"

module Rubik
  module LLM
    class OllamaProvider < BaseProvider
      attr_reader :endpoint, :model, :formatter
      alias host endpoint

      def initialize(endpoint: nil, host: nil, model: "llama3", formatter: OllamaFormatter.new)
        @endpoint = endpoint || host || "http://localhost:11434"
        @model = model
        @formatter = formatter || OllamaFormatter.new
      end

      def complete(messages, opts = {})
        target_model = opts[:model] || @model
        chat_endpoint = @endpoint.end_with?("/api/chat") ? @endpoint : "#{@endpoint}/api/chat"

        payload = {
          model: target_model,
          messages: format_messages(messages),
          stream: false
        }

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(chat_endpoint, payload: payload)

        msg_content = res_json.dig("message", "content") || ""
        in_tokens = res_json["prompt_eval_count"] || estimate_tokens(messages.map { |m| m[:content] || m["content"] }.join)
        out_tokens = res_json["eval_count"] || estimate_tokens(msg_content)

        raw_tool_calls = res_json.dig("message", "tool_calls") || []
        parsed_tool_calls = raw_tool_calls.map do |tc|
          fn = tc["function"] || {}
          args = fn["arguments"]
          args = JSON.parse(args) if args.is_a?(String) rescue {}
          {
            "id" => tc["id"] || "call_#{rand(1000..9999)}",
            "tool" => fn["name"],
            "args" => args || {}
          }
        end

        Response.new(
          text: msg_content,
          usage: { input_tokens: in_tokens, output_tokens: out_tokens },
          raw: res_json,
          tool_calls: parsed_tool_calls
        )
      end

      # Streaming variant. Ollama uses NDJSON — one JSON object per line.
      # The provider's HTTPClient call already speaks NDJSON (we just don't
      # frame events into \n\n blocks on the client side); each line is fed
      # to the formatter via the same `{ type:, data: }` event shape, which
      # the OllamaFormatter normalizes into a Chunk.
      def stream_chat(messages, opts = {}, &block)
        target_model = opts[:model] || @model
        chat_endpoint = @endpoint.end_with?("/api/chat") ? @endpoint : "#{@endpoint}/api/chat"

        payload = {
          model: target_model,
          messages: format_messages(messages),
          stream: true
        }
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        return to_enum(:stream_chat, messages, opts) unless block

        HTTPClient.post_stream_json(
          chat_endpoint,
          payload: payload,
          timeout: opts[:timeout] || 120,
          terminator: SSEParser::NDJSON_TERMINATOR
        ) do |event|
          # Ollama's NDJSON may not include event types. The `data` field
          # carries the full JSON line, and `type` is empty. Forward both
          # shapes — the formatter ignores `type` and parses `data`.
          chunk = @formatter.parse_stream_event(event)
          next if chunk.nil?
          block.call(chunk)
        end
      end

      private

      def format_messages(messages)
        @formatter.format_messages(messages)
      end

      def format_tools(tools)
        @formatter.format_tools(tools)
      end
    end
  end
end
