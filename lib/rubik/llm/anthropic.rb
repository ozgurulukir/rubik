# frozen_string_literal: true

require_relative "provider"
require_relative "client"
require_relative "formatter"

module Rubik
  module LLM
    class AnthropicProvider < BaseProvider
      attr_reader :name, :model, :formatter, :headers, :api_key, :api_key_env

      # Extended-thinking support by model line (Anthropic docs, 2026-10):
      #   :adaptive — 4.6+ and the 5.x/Fable lines: `thinking: {type: "adaptive"}`
      #     with an `output_config` effort; the legacy budget_tokens form is
      #     REJECTED with a 400 from 4.7 onward.
      #   :legacy   — claude-3-7-sonnet through the 4.5 line: the manual
      #     `thinking: {type: "enabled", budget_tokens: N}` form is the only
      #     accepted mode.
      #   nil       — 3.5-and-earlier lines accept no thinking at all, and
      #     unrecognized names (custom aliases/proxies) get no auto thinking.
      def self.thinking_mode_for(model_name)
        s = model_name.to_s
        return :legacy if s.include?("claude-3-7-sonnet")
        return nil if s.match?(/\Aclaude-[23]/) # number-first 2.x/3.x lines (3-7 handled above)

        # Single-digit captures: Anthropic versions are one digit per segment,
        # so a snapshot date suffix (claude-sonnet-4-20250514) can never be
        # swallowed as the minor version.
        version = s.match(/\Aclaude-(?:sonnet|opus|haiku|fable)-(\d)(?:-(\d))?/)
        return nil unless version

        major = version[1].to_i
        minor = version[2].to_i
        major > 4 || (major == 4 && minor >= 6) ? :adaptive : :legacy
      end

      def initialize(name: nil, model: "claude-sonnet-5-5", formatter: AnthropicFormatter.new, headers: {},
                     api_key: nil, api_key_env: nil)
        super()
        @name = name.to_s.downcase
        @model = model
        @formatter = formatter || AnthropicFormatter.new
        @headers = headers || {}
        # Plan: Anthropic api_key / api_key_env were silently dropped from the
        # provider spec, so every Anthropic deployment (custom or registered
        # via config) failed auth with no diagnostic. Both a direct api_key and
        # an env-var source are honored, mirroring OpenAICompatibleProvider.
        @api_key = api_key
        @api_key_env = api_key_env
      end

      # Resolve the Anthropic key from (in order of precedence): an explicit
      # per-call opts[:api_key], the provider-level @api_key, and finally the
      # environment variable named by @api_key_env (default ANTHROPIC_API_KEY).
      def resolve_api_key(opts = {})
        return opts[:api_key] if opts.key?(:api_key) && !opts[:api_key].nil?
        return @api_key if @api_key && !@api_key.to_s.empty?

        env_name = opts[:api_key_env] || @api_key_env || "ANTHROPIC_API_KEY"
        ENV.fetch(env_name, nil)
      end

      def complete(messages, opts = {})
        api_key = resolve_api_key(opts)
        unless api_key && !api_key.to_s.empty?
          raise ClientError, "No Anthropic API key available: set ANTHROPIC_API_KEY, pass api_key in config, " \
                             "or configure api_key_env for the 'anthropic' provider."
        end

        messages = Rubik::LLM::MessageSanitizer.normalize(messages)
        target_model = opts[:model] || @model
        # Allow endpoint override (opts[:endpoint] for tests/proxies)
        endpoint = opts[:endpoint] || "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }
        @headers.each { |k, v| headers[k.to_s] = v.to_s }
        headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        # Messages API contract: exactly one top-level `system` field is
        # allowed, so multiple system messages are deliberately joined here,
        # never sent inline.
        system_msgs, user_msgs = messages.partition { |m| m[:role] == "system" || m["role"] == "system" }

        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")
        payload = build_payload(target_model, user_msgs, system_text, opts, stream: false)

        timeout = opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        res_json = HTTPClient.post_json(
          endpoint,
          headers: headers,
          payload: payload,
          timeout: timeout,
          open_timeout: open_timeout,
          on_retry: opts[:on_retry]
        )

        content_blocks = res_json["content"] || []
        text_blocks = content_blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }
        text = text_blocks.join("\n")

        thought_blocks = content_blocks.select { |b| b["type"] == "thinking" }.map { |b| b["thinking"] }
        thought = thought_blocks.empty? ? nil : thought_blocks.join("\n")

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
          tool_calls: parsed_tool_calls,
          thought: thought
        )
      end

      # Streaming variant. Yields Chunks. Without a block, returns an
      # Enumerator (via `to_enum`) so the caller can chain `.each`.
      def stream_chat(messages, opts = {}, &block)
        api_key = resolve_api_key(opts)
        unless api_key && !api_key.to_s.empty?
          raise ClientError, "No Anthropic API key available: set ANTHROPIC_API_KEY, pass api_key in config, " \
                             "or configure api_key_env for the 'anthropic' provider."
        end

        messages = Rubik::LLM::MessageSanitizer.normalize(messages)
        target_model = opts[:model] || @model
        # Allow endpoint override (opts[:endpoint] for tests/proxies;
        # default to the public Anthropic API).
        endpoint = opts[:endpoint] || "https://api.anthropic.com/v1/messages"

        headers = {
          "x-api-key" => api_key,
          "anthropic-version" => "2023-06-01"
        }
        @headers.each { |k, v| headers[k.to_s] = v.to_s }
        headers.merge!(opts[:headers]) if opts[:headers].is_a?(Hash)

        # Same Messages API contract as #complete: exactly one top-level
        # `system` field is allowed, so multiple system messages are
        # deliberately joined here rather than passed inline.
        system_msgs, user_msgs = messages.partition { |m| m[:role] == "system" || m["role"] == "system" }
        system_text = system_msgs.map { |m| m[:content] || m["content"] }.join("\n\n")

        payload = build_payload(target_model, user_msgs, system_text, opts, stream: true)

        return to_enum(:stream_chat, messages, opts) unless block

        timeout = opts[:idle_timeout] || opts[:timeout] || opts[:stream_timeout] || 120
        open_timeout = opts[:open_timeout] || 15

        HTTPClient.post_stream_json(
          endpoint,
          headers: headers,
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

      def build_payload(target_model, user_msgs, system_text, opts, stream: false)
        max_tokens = (opts[:max_tokens] || 1024).to_i
        payload = {
          model: target_model,
          messages: format_messages(user_msgs),
          max_tokens: max_tokens
        }
        payload[:stream] = true if stream
        payload[:system] = system_text unless system_text.to_s.empty?
        payload[:tools] = format_tools(opts[:tools]) if opts[:tools] && !opts[:tools].empty?

        thinking_opt = opts[:thinking]
        thinking_disabled = [false, :disabled].include?(thinking_opt)
        ratio = (opts[:thinking_budget_ratio] || 0.5).to_f
        # Thinking is on for every model line that supports it unless
        # explicitly disabled; thinking_budget_ratio only shapes the legacy
        # budget form — adaptive models reason as they see fit.
        mode = self.class.thinking_mode_for(target_model)

        if thinking_opt.is_a?(Hash)
          payload[:thinking] = thinking_opt
        elsif !thinking_disabled && (thinking_opt == true || mode)
          if mode == :legacy
            if max_tokens > 2048
              budget = [(max_tokens * ratio).to_i, 1024].max
              budget = [budget, max_tokens - 1024].min
              payload[:thinking] = { type: "enabled", budget_tokens: budget } if budget >= 1024
            end
          else
            # Adaptive models reject the legacy form outright, and for
            # unrecognized names adaptive is the modern-generation default.
            payload[:thinking] = { type: "adaptive" }
            payload[:output_config] = { effort: "high" }
          end
        end

        if payload[:thinking]
          payload[:temperature] = 1.0 if opts.key?(:temperature)
        elsif opts.key?(:temperature)
          payload[:temperature] = opts[:temperature]
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
