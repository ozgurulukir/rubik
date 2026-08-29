# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"
require "json"

module Rubik
  module LLM
    class OpenAICompatibleProvider < BaseProvider
      attr_reader :name, :endpoint, :api_key, :api_key_env, :headers, :model, :default_context_limit, :default_max_output_tokens, :formatter

      def self.normalize_endpoint(url)
        raw = url.to_s.strip
        return raw if raw.empty?

        clean = raw.sub(%r{/+\z}, "")
        return clean if clean.end_with?("/chat/completions") || clean.end_with?("/completions")

        if clean == "https://api.deepseek.com"
          "https://api.deepseek.com/chat/completions"
        elsif clean == "https://api.deepseek.com/v1"
          "https://api.deepseek.com/v1/chat/completions"
        elsif ["https://openrouter.ai", "https://openrouter.ai/api"].include?(clean)
          "https://openrouter.ai/api/v1/chat/completions"
        elsif clean == "https://api.openai.com"
          "https://api.openai.com/v1/chat/completions"
        elsif ["https://api.cline.bot", "https://api.cline.bot/api"].include?(clean)
          "https://api.cline.bot/api/v1/chat/completions"
        elsif clean =~ %r{/v\d+\z}i || clean.end_with?("/api")
          "#{clean}/chat/completions"
        else
          "#{clean}/v1/chat/completions"
        end
      end

      def initialize(name: "openai_compatible", endpoint: "https://api.openai.com/v1/chat/completions", api_key: nil, api_key_env: nil, headers: {},
                     model: "gpt-4o", default_context_limit: 32_768, default_max_output_tokens: nil, formatter: OpenAIFormatter.new)
        @name = name.to_s.downcase
        @endpoint = self.class.normalize_endpoint(endpoint)
        @api_key = api_key
        @api_key_env = api_key_env
        @headers = headers || {}
        @model = model.to_s
        @default_context_limit = default_context_limit.to_i
        @default_max_output_tokens = default_max_output_tokens&.to_i
        @formatter = formatter || OpenAIFormatter.new
      end

      def complete(messages, opts = {})
        resolved_key = opts[:api_key] || @api_key || (ENV.fetch(@api_key_env, nil) if @api_key_env)
        target_model = opts[:model] || @model
        target_endpoint = self.class.normalize_endpoint(opts[:endpoint] || @endpoint)
        messages = Rubik::LLM::MessageSanitizer.normalize(messages)

        req_headers = { "Content-Type" => "application/json" }
        req_headers["Authorization"] = "Bearer #{resolved_key}" if resolved_key && !resolved_key.empty?

        # Merge custom headers (e.g. OpenRouter HTTP-Referer, X-Title)
        @headers.each do |k, v|
          req_headers[k.to_s] = v.to_s
        end

        formatted_msgs = format_messages(messages)

        payload = {
          model: target_model,
          messages: formatted_msgs
        }

        payload[:temperature] = opts[:temperature] if opts.key?(:temperature)
        payload[:max_tokens] = opts[:max_tokens] if opts.key?(:max_tokens)

        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        res_json = HTTPClient.post_json(
          target_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: opts[:timeout] || 120,
          on_retry: opts[:on_retry]
        )

        root_json = res_json["data"].is_a?(Hash) && res_json["data"]["choices"] ? res_json["data"] : res_json
        msg = root_json.dig("choices", 0, "message") || {}
        text = msg["content"] || ""
        usage = root_json["usage"] || res_json["usage"] || {}

        raw_tool_calls = msg["tool_calls"] || []
        parsed_tool_calls = raw_tool_calls.map do |tc|
          fn = tc["function"] || {}
          args = fn["arguments"]
          begin
            args = JSON.parse(args) if args.is_a?(String)
          rescue
            {}
          end
          {
            "id" => tc["id"] || "call_#{rand(1000..9999)}",
            "tool" => fn["name"],
            "args" => args || {}
          }
        end

        in_tokens = usage["prompt_tokens"] || usage["input_tokens"] || estimate_tokens(messages.map { |m| m[:content] || m["content"] }.join)
        out_tokens = usage["completion_tokens"] || usage["output_tokens"] || estimate_tokens(text)

        Response.new(
          text: text,
          usage: {
            input_tokens: in_tokens,
            output_tokens: out_tokens
          },
          raw: res_json,
          tool_calls: parsed_tool_calls
        )
      end

      # Streaming variant. Yields Chunks. Without a block, returns an
      # Enumerator (via `to_enum`) so the caller can chain `.each`.
      def stream_chat(messages, opts = {}, &block)
        resolved_key = opts[:api_key] || @api_key || (ENV.fetch(@api_key_env, nil) if @api_key_env)
        target_model = opts[:model] || @model
        target_endpoint = self.class.normalize_endpoint(opts[:endpoint] || @endpoint)
        messages = Rubik::LLM::MessageSanitizer.normalize(messages)

        req_headers = { "Content-Type" => "application/json" }
        req_headers["Authorization"] = "Bearer #{resolved_key}" if resolved_key && !resolved_key.empty?
        @headers.each { |k, v| req_headers[k.to_s] = v.to_s }

        formatted_msgs = format_messages(messages)

        payload = {
          model: target_model,
          messages: formatted_msgs,
          stream: true
        }
        payload[:temperature] = opts[:temperature] if opts.key?(:temperature)
        payload[:max_tokens] = opts[:max_tokens] if opts.key?(:max_tokens)
        # Request final usage in the last chunk
        payload[:stream_options] = { include_usage: true } if opts[:include_usage] != false
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        return to_enum(:stream_chat, messages, opts) unless block

        HTTPClient.post_stream_json(
          target_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: opts[:timeout] || 60
        ) do |event|
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
