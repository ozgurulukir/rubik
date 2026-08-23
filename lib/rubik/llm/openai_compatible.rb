# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require "json"

module Rubik
  module LLM
    class OpenAICompatibleProvider < BaseProvider
      attr_reader :name, :endpoint, :api_key, :api_key_env, :headers, :model, :default_context_limit

      def initialize(name: "openai_compatible", endpoint: "https://api.openai.com/v1/chat/completions", api_key: nil, api_key_env: nil, headers: {}, model: "gpt-4o", default_context_limit: 32768)
        @name = name.to_s.downcase
        @endpoint = endpoint.to_s
        @api_key = api_key
        @api_key_env = api_key_env
        @headers = headers || {}
        @model = model.to_s
        @default_context_limit = default_context_limit.to_i
      end

      def complete(messages, opts = {})
        resolved_key = opts[:api_key] || @api_key || (ENV[@api_key_env] if @api_key_env)
        target_model = opts[:model] || @model
        target_endpoint = opts[:endpoint] || @endpoint

        req_headers = { "Content-Type" => "application/json" }
        req_headers["Authorization"] = "Bearer #{resolved_key}" if resolved_key && !resolved_key.empty?

        # Merge custom headers (e.g. OpenRouter HTTP-Referer, X-Title)
        @headers.each do |k, v|
          req_headers[k.to_s] = v.to_s
        end

        payload = {
          model: target_model,
          messages: messages
        }

        payload[:temperature] = opts[:temperature] if opts.key?(:temperature)
        payload[:max_tokens] = opts[:max_tokens] if opts.key?(:max_tokens)

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(target_endpoint, headers: req_headers, payload: payload)

        msg = res_json.dig("choices", 0, "message") || {}
        text = msg["content"] || ""
        usage = res_json["usage"] || {}

        raw_tool_calls = msg["tool_calls"] || []
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

      private

      def format_tools(tools)
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
    end
  end
end
