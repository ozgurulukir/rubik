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

      def format_messages(messages)
        messages
      end

      def format_tools(tools)
        tools
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
    end
  end
end
