# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"

module Rubik
  module LLM
    class AnthropicProvider < BaseProvider
      attr_reader :model, :formatter

      def initialize(model: "claude-3-7-sonnet-20250219", formatter: AnthropicFormatter.new)
        super()
        @model = model
        @formatter = formatter || AnthropicFormatter.new
      end

      def complete(messages, opts = {})
        api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
        raise ClientError, "ANTHROPIC_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        messages = Rubik::LLM::MessageSanitizer.normalize(messages)
        target_model = opts[:model] || @model
        # Allow endpoint override (opts[:endpoint] for tests/proxies)
        endpoint = opts[:endpoint] || "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }

        # Messages API contract: exactly one top-level `system` field is
        # allowed, so multiple system messages are deliberately joined here,
        # never sent inline.
        system_msgs, user_msgs = messages.partition { |m| m[:role] == "system" || m["role"] == "system" }

        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")

        payload = {
          model: target_model,
          messages: format_messages(user_msgs),
          max_tokens: opts[:max_tokens] || 1024
        }
        payload[:system] = system_text unless system_text.empty?

        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        res_json = HTTPClient.post_json(
          endpoint,
          headers: headers,
          payload: payload,
          timeout: opts[:timeout] || 120,
          on_retry: opts[:on_retry]
        )

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

      # Streaming variant. Yields Chunks. Without a block, returns an
      # Enumerator (via `to_enum`) so the caller can chain `.each`.
      def stream_chat(messages, opts = {}, &block)
        api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
        raise ClientError, "ANTHROPIC_API_KEY environment variable is not set" if api_key.nil? || api_key.empty?

        messages = Rubik::LLM::MessageSanitizer.normalize(messages)
        target_model = opts[:model] || @model
        # Allow endpoint override (opts[:endpoint] for tests/proxies;
        # default to the public Anthropic API).
        endpoint = opts[:endpoint] || "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }

        # Same Messages API contract as #complete: exactly one top-level
        # `system` field is allowed, so multiple system messages are
        # deliberately joined here rather than passed inline.
        system_msgs, user_msgs = messages.partition { |m| m[:role] == "system" || m["role"] == "system" }
        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")

        payload = {
          model: target_model,
          messages: format_messages(user_msgs),
          max_tokens: opts[:max_tokens] || 1024,
          stream: true
        }
        payload[:system] = system_text unless system_text.empty?
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        return to_enum(:stream_chat, messages, opts) unless block

        HTTPClient.post_stream_json(
          endpoint,
          headers: headers,
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
