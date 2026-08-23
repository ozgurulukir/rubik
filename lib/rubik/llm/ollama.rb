# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require "json"

module Rubik
  module LLM
    class OllamaProvider < BaseProvider
      attr_reader :host, :model

      def initialize(host: "http://localhost:11434", model: "llama3")
        @host = host
        @model = model
      end

      def complete(messages, opts = {})
        target_model = opts[:model] || @model
        endpoint = "#{@host}/api/chat"

        payload = {
          model: target_model,
          messages: messages,
          stream: false
        }

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(endpoint, payload: payload)

        msg_content = res_json.dig("message", "content") || ""
        in_tokens = res_json["prompt_eval_count"] || estimate_tokens(messages.map { |m| m[:content] || m["content"] }.join)
        out_tokens = res_json["eval_count"] || estimate_tokens(msg_content)

        raw_tool_calls = res_json.dig("message", "tool_calls") || []
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
          text: msg_content,
          usage: { input_tokens: in_tokens, output_tokens: out_tokens },
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
