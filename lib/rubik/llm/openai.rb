# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require "json"

module Rubik
  module LLM
    class OpenAIProvider < BaseProvider
      attr_reader :model

      def initialize(model: "gpt-4o")
        @model = model
      end

      def complete(messages, opts = {})
        api_key = ENV["OPENAI_API_KEY"]
        raise ClientError, "OPENAI_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        target_model = opts[:model] || @model
        endpoint = "https://api.openai.com/v1/chat/completions"

        headers = { "Authorization" => "Bearer #{api_key}" }
        payload = {
          model: target_model,
          messages: messages
        }

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(endpoint, headers: headers, payload: payload)

        msg = res_json.dig("choices", 0, "message") || {}
        text = msg["content"] || ""
        usage = res_json["usage"] || {}

        raw_tool_calls = msg["tool_calls"] || []
        parsed_tool_calls = raw_tool_calls.map do |tc|
          fn = tc["function"] || {}
          args = fn["arguments"]
          args = JSON.parse(args) if args.is_a?(String)
          {
            "id" => tc["id"] || "call_#{rand(1000..9999)}",
            "tool" => fn["name"],
            "args" => args || {}
          }
        end

        Response.new(
          text: text,
          usage: {
            input_tokens: usage["prompt_tokens"] || 0,
            output_tokens: usage["completion_tokens"] || 0
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
    end
  end
end
