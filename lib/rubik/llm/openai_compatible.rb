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
                     model: "gpt-4o", default_context_limit: 32_768, default_max_output_tokens: nil, tool_native: true, formatter: nil)
        super()
        @name = name.to_s.downcase
        @endpoint = self.class.normalize_endpoint(endpoint)
        @api_key = api_key
        @api_key_env = api_key_env
        @headers = headers || {}
        @model = model.to_s
        @default_context_limit = default_context_limit.to_i
        @default_max_output_tokens = default_max_output_tokens&.to_i
        # Plan 85 D-5: config'ten tool_native:false verilirse prefix'li user mesajı kullanılır.
        @formatter = formatter || OpenAIFormatter.new(tool_native: tool_native)
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
        req_headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        formatted_msgs = format_messages(messages)
        payload = build_payload(target_model, formatted_msgs, opts, stream: false)

        timeout = opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        res_json = HTTPClient.post_json(
          target_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: timeout,
          open_timeout: open_timeout,
          on_retry: opts[:on_retry]
        )

        root_json = res_json["data"].is_a?(Hash) && res_json["data"]["choices"] ? res_json["data"] : res_json
        msg = root_json.dig("choices", 0, "message") || {}
        text = msg["content"] || ""
        thought = msg["reasoning_content"] || msg["reasoning"] || msg["thought"]
        thought = nil if thought.to_s.empty?
        usage = root_json["usage"] || res_json["usage"] || {}

        raw_tool_calls = msg["tool_calls"] || []
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

        in_tokens = usage["prompt_tokens"] || usage["input_tokens"] || estimate_tokens(messages.map { |m| m[:content] || m["content"] }.join)
        out_tokens = usage["completion_tokens"] || usage["output_tokens"] || estimate_tokens(text)

        Response.new(
          text: text,
          usage: {
            input_tokens: in_tokens,
            output_tokens: out_tokens
          },
          raw: res_json,
          tool_calls: parsed_tool_calls,
          thought: thought
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
        req_headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        formatted_msgs = format_messages(messages)
        payload = build_payload(target_model, formatted_msgs, opts, stream: true)

        return to_enum(:stream_chat, messages, opts) unless block

        timeout = opts[:idle_timeout] || opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        HTTPClient.post_stream_json(
          target_endpoint,
          headers: req_headers,
          payload: payload,
          timeout: timeout,
          open_timeout: open_timeout,
          idle_timeout: opts[:idle_timeout]
        ) do |event|
          chunk = @formatter.parse_stream_event(event)
          next if chunk.nil?

          block.call(chunk)
        end
      end

      private

      def reasoning_model?(model_name, opts)
        return true if opts.key?(:reasoning_effort)
        return true if model_name.to_s.match?(/\A(o[134](-[a-z0-9]+)?|o1|o3|o4)\b/i)

        false
      end

      def build_payload(target_model, formatted_msgs, opts, stream: false)
        payload = {
          model: target_model,
          messages: formatted_msgs
        }
        payload[:stream] = true if stream
        payload[:stream_options] = { include_usage: true } if stream && opts[:include_usage] != false
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        if reasoning_model?(target_model, opts)
          tokens = opts[:max_completion_tokens] || opts[:max_tokens]
          payload[:max_completion_tokens] = tokens.to_i if tokens
          payload[:reasoning_effort] = opts[:reasoning_effort].to_s if opts[:reasoning_effort]
        else
          payload[:temperature] = opts[:temperature] if opts.key?(:temperature)
          if opts.key?(:max_completion_tokens)
            payload[:max_completion_tokens] = opts[:max_completion_tokens].to_i
          elsif opts.key?(:max_tokens)
            payload[:max_tokens] = opts[:max_tokens].to_i
          end
        end

        payload
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
