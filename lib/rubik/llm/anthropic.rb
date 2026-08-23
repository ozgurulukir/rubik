# frozen_string_literal: true

require_relative "provider"
require_relative "client"

module Rubik
  module LLM
    class AnthropicProvider < BaseProvider
      attr_reader :model

      def initialize(model: "claude-3-5-sonnet-20240620")
        @model = model
      end

      def complete(messages, opts = {})
        api_key = ENV["ANTHROPIC_API_KEY"]
        raise ClientError, "ANTHROPIC_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        target_model = opts[:model] || @model
        endpoint = "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }

        # Anthropic requires system prompt to be at top level payload, not in messages array
        system_msgs = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
        user_msgs = messages.reject { |m| m[:role] == "system" || m["role"] == "system" }

        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")

        payload = {
          model: target_model,
          messages: format_messages(user_msgs),
          max_tokens: opts[:max_tokens] || 1024
        }
        payload[:system] = system_text unless system_text.empty?

        if opts[:tools] && !opts[:tools].empty?
          payload[:tools] = format_tools(opts[:tools])
        end

        res_json = HTTPClient.post_json(endpoint, headers: headers, payload: payload)

        content_blocks = res_json["content"] || []
        text_blocks = content_blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }
        text = text_blocks.join("\n")

        tool_blocks = content_blocks.select { |b| b["type"] == "tool_use" }
        parsed_tool_calls = tool_blocks.map do |b|
          {
            "id" => b["id"] || "call_#{rand(1000..9999)}",
            "tool" => b["name"],
            "args" => b["input"] || {}
          }
        end

        usage = res_json["usage"] || {}

        Response.new(
          text: text,
          usage: {
            input_tokens: usage["input_tokens"] || 0,
            output_tokens: usage["output_tokens"] || 0
          },
          raw: res_json,
          tool_calls: parsed_tool_calls
        )
      end

      private

      def format_messages(messages)
        messages.map do |m|
          role = (m[:role] || m["role"]).to_s
          if role == "assistant" && (m[:tool_calls] || m["tool_calls"])
            content = []
            txt = m[:content] || m["content"]
            content << { "type" => "text", "text" => txt } if txt && !txt.empty?
            (m[:tool_calls] || m["tool_calls"] || []).each do |tc|
              call_id = (tc["id"] || tc[:id] || "call_#{rand(1000..9999)}").to_s
              content << {
                "type" => "tool_use",
                "id" => call_id,
                "name" => tc["tool"] || tc[:tool],
                "input" => tc["args"] || tc[:args] || {}
              }
            end
            { "role" => "assistant", "content" => content }
          elsif role == "tool"
            call_id = (m[:tool_call_id] || m["tool_call_id"] || m[:call_id] || m["call_id"] || "call_default").to_s
            {
              "role" => "user",
              "content" => [
                {
                  "type" => "tool_result",
                  "tool_use_id" => call_id,
                  "content" => m[:content] || m["content"] || ""
                }
              ]
            }
          else
            {
              "role" => role,
              "content" => m[:content] || m["content"] || ""
            }
          end
        end
      end

      def format_tools(tools)
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
    end
  end
end
