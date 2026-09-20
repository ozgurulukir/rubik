# frozen_string_literal: true

require "json"
require_relative "../../prompt"
require_relative "../../tools/truncator"

module Rubik
  module Orchestrator
    module Subagent
      # Step execution loop, compaction evaluation, emergency recovery, and tool dispatch
      # extracted from Instance to satisfy module hygiene and maintain vertical cohesion (Plan 95).
      module StepRunner
        def execute_steps_with_provider
          loop do
            while @current_step < @max_steps && @state == :running
              @current_step += 1
              drain_inbox_into_history
              inject_step_warning_if_needed
              evaluate_subagent_context_compaction!

              opts = { tools: (@tool_registry.respond_to?(:schemas) ? @tool_registry.schemas : []) }
              opts[:model] = @model unless @model.nil? || @model == "inherit"

              content, tool_calls = parse_provider_response(invoke_provider_with_recovery(opts))
              @history << {
                role: "assistant",
                content: (content.empty? ? nil : content),
                tool_calls: (tool_calls.empty? ? nil : tool_calls)
              }

              next unless tool_calls.empty? || execute_tool_calls(tool_calls, fallback_content: content)

              @result = content.to_s.strip if tool_calls.empty?
              @state = :completed
              return
            end

            break unless @state == :running && @current_step >= @max_steps
            break unless pause_and_await_budget_expansion!
          end
        end

        def evaluate_subagent_context_compaction!
          return unless @context_limit&.positive?

          context_cfg = @config.respond_to?(:fetch) ? @config.fetch("context", {}) : {}
          context_cfg = {} unless context_cfg.is_a?(Hash)
          needs = Rubik::Prompt::ContextCompactor.needs_compaction?(
            @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg
          )
          return unless needs

          compacted = Rubik::Prompt::ContextCompactor.compact_history(
            @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg
          )
          @history.replace(compacted)
        end

        def invoke_provider_with_recovery(opts)
          retry_attempted = false
          begin
            invoke_provider(opts)
          rescue StandardError => e
            auto_recover = @config.respond_to?(:fetch) ? @config.fetch("context.auto_recover_on_overflow", true) : true
            if !retry_attempted && auto_recover && context_overflow_error?(e)
              retry_attempted = true
              compact_cfg = @config.respond_to?(:fetch) ? @config.fetch("context", {}) : {}
              compact_cfg = {} unless compact_cfg.is_a?(Hash)
              Rubik::Prompt::EmergencyCompactor.compact!(
                @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: compact_cfg
              )
              retry
            end
            raise e
          end
        end

        def context_overflow_error?(err)
          err.message.to_s.match?(/context|context_length|maximum context|prompt is too long|token limit|too many tokens/i)
        end

        def invoke_provider(opts)
          effective_opts = opts.dup
          effective_opts[:timeout] ||= 90
          effective_opts[:open_timeout] ||= 15
          effective_opts[:context_limit] ||= @context_limit if @context_limit
          effective_opts[:max_tokens] ||= @max_output_tokens if @max_output_tokens&.positive?

          return @provider.complete(@history, effective_opts) if @provider.respond_to?(:complete)
          return @provider.chat(@history, **effective_opts) if @provider.respond_to?(:chat)

          raise "Provider #{@provider.class} does not support complete or chat"
        end

        def parse_provider_response(response)
          content = extract_response_content(response)
          raw_tcs = response.respond_to?(:tool_calls) ? response.tool_calls : []
          tool_calls = (raw_tcs || []).map.with_index do |tc, idx|
            cid = tc["id"] || tc[:id] || "call_#{@id}_#{@current_step}_#{idx + 1}"
            t_name = tc["tool"] || tc[:tool] || tc["name"] || tc[:name]
            t_args = tc["args"] || tc[:args] || tc["arguments"] || tc[:arguments] || {}
            t_args = JSON.parse(t_args) if t_args.is_a?(String)
            { "id" => cid, "tool" => t_name, "args" => t_args }
          end
          [content, tool_calls]
        end

        def extract_response_content(response)
          return response.text.to_s if response.respond_to?(:text)
          return response.content.to_s if response.respond_to?(:content)

          response.to_s
        end

        def drain_inbox_into_history
          until @inbox.empty?
            begin
              msg = @inbox.pop(true)
              @history << { role: "user", content: "[Message from supervisor]: #{msg}" } if msg
            rescue ThreadError
              break
            end
          end
        end

        def execute_tool_calls(tool_calls, fallback_content: nil)
          finished = false
          tool_calls.each do |tc|
            name = tc["tool"]
            args = tc["args"] || {}
            if name == "finish"
              @result = args["message"] || args[:message] || fallback_content || "Completed"
              finished = true
              break
            end

            tool = @tool_registry.respond_to?(:get) ? @tool_registry.get(name) : nil
            output = dispatch_subagent_tool(tool, name, args)
            @history << { role: "tool", tool_call_id: tc["id"], tool_name: name, content: output.to_s }
          end
          finished
        end

        def dispatch_subagent_tool(tool, name, args)
          return "Tool '#{name}' is not available in subagent toolset." unless tool

          raw = tool.execute(args)
          out_str = raw.respond_to?(:output) ? raw.output.to_s : raw.to_s
          max_chars = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_chars", 12_000) : 12_000) || 12_000
          max_lines = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_lines", 300) : 300) || 300
          trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars.to_i, max_lines: max_lines.to_i)
          trunc[:text]
        rescue StandardError => e
          "Tool execution error: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
