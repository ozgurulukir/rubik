# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"
require "json"

module Rubik
  module LLM
    class OllamaProvider < BaseProvider
      attr_reader :name, :endpoint, :model, :num_ctx, :formatter, :headers
      alias host endpoint

      def initialize(name: nil, endpoint: nil, host: nil, model: "llama3", num_ctx: nil, formatter: OllamaFormatter.new, headers: {})
        super()
        @name = name.to_s.downcase
        @endpoint = endpoint || host || "http://localhost:11434"
        @model = model
        @num_ctx = num_ctx
        @formatter = formatter || OllamaFormatter.new
        @headers = headers || {}
      end

      def complete(messages, opts = {})
        target_model = opts[:model] || @model
        chat_endpoint = @endpoint.end_with?("/api/chat") ? @endpoint : "#{@endpoint}/api/chat"

        req_headers = {}
        @headers.each { |k, v| req_headers[k.to_s] = v.to_s }
        req_headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        payload = {
          model: target_model,
          messages: format_messages(messages),
          stream: false
        }
        apply_num_ctx!(payload, opts)

        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        timeout = opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        res_json = HTTPClient.post_json(
          chat_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: timeout,
          open_timeout: open_timeout,
          on_retry: opts[:on_retry]
        )

        msg_content = res_json.dig("message", "content") || ""
        in_tokens = res_json["prompt_eval_count"] || estimate_tokens(messages.map { |m| m[:content] || m["content"] }.join)
        out_tokens = res_json["eval_count"] || estimate_tokens(msg_content)

        raw_tool_calls = res_json.dig("message", "tool_calls") || []
        parsed_tool_calls = raw_tool_calls.map do |tc|
          fn = tc["function"] || {}
          args = fn["arguments"]
          malformed = nil
          if args.is_a?(String)
            begin
              parsed = JSON.parse(args)
              if parsed.is_a?(Hash)
                args = parsed
              else
                malformed = args
                args = {}
              end
            rescue JSON::ParserError
              # Issue #55 3.4: the degrade carries the rejected payload so
              # the executor can echo it back to the model in the error row.
              malformed = args
              args = {}
            end
          elsif !args.is_a?(Hash) && !args.nil?
            malformed = args.to_s
            args = {}
          end
          row = {
            "id" => tc["id"] || "call_#{rand(1000..9999)}",
            "tool" => fn["name"],
            "args" => args || {}
          }
          row["malformed_args"] = malformed if malformed
          row
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
        apply_num_ctx!(payload, opts)
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        return to_enum(:stream_chat, messages, opts) unless block

        req_headers = {}
        @headers.each { |k, v| req_headers[k.to_s] = v.to_s }
        req_headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        timeout = opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        HTTPClient.post_stream_json(
          chat_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: timeout,
          open_timeout: open_timeout,
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

      # Plan 61 D-1: without num_ctx the Ollama server silently clips the
      # prompt head to its own default window (~2-4k tokens) — the model
      # never sees the system prompt or earlier turns. Precedence: explicit
      # request opt > provider-level config (providers.<name>.num_ctx) >
      # the orchestrator's compaction target (opts[:context_limit]).
      def apply_num_ctx!(payload, opts)
        num_ctx = opts[:num_ctx] || @num_ctx || opts[:context_limit]
        max_tokens = opts[:max_tokens] || opts[:max_output_tokens]
        opts_hash = {}
        opts_hash[:num_ctx] = num_ctx.to_i if num_ctx&.to_i&.positive?
        opts_hash[:num_predict] = max_tokens.to_i if max_tokens&.to_i&.positive?
        payload[:options] = opts_hash unless opts_hash.empty?
      end

      def format_messages(messages)
        @formatter.format_messages(messages)
      end

      def format_tools(tools)
        @formatter.format_tools(tools)
      end
    end
  end
end
