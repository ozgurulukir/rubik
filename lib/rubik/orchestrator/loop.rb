# frozen_string_literal: true

require "json"
require_relative "../prompt"

module Rubik
  module Orchestrator
    class Loop
      attr_reader :max_steps, :step_count, :history, :model, :total_tokens, :warn_at_ratio, :runtime_manager, :loop_context, :context_limit, :max_output_tokens, :config

      def initialize(provider:, tool_registry:, max_steps: 40, warn_at_ratio: 0.75, model: nil, on_step: nil, shell: nil, context_limit: nil, max_output_tokens: nil)
        @provider = provider
        @tool_registry = tool_registry
        @max_steps = (max_steps || 40).to_i
        @warn_at_ratio = (warn_at_ratio || 0.75).to_f
        @model = model
        @on_step = on_step
        @shell = shell
        @buffer_manager = shell&.buffer_manager
        @snapshot_store = shell&.snapshot_store
        @context_index = shell&.context_index
        @lsp_manager = shell&.lsp_manager
        @config = shell&.config
        @root_dir = File.expand_path(shell&.buffer_manager&.root_dir || Dir.pwd)
        @runtime_manager = shell&.runtime_manager
        @context_limit = context_limit || 32_768
        @max_output_tokens = max_output_tokens || 4_096
        @loop_context = nil
        @step_count = 0
        @history = []
        @total_tokens = { input: 0, output: 0 }
        @invalid_tool_count = 0
      end

      def extend_budget(extra_steps)
        @max_steps += extra_steps.to_i
      end

      def run(task_prompt, model: nil, plan_only: false, goal_mode: false, initial_context: nil, conversation_history: [])
        @step_count = 0
        @history = []
        @total_tokens = { input: 0, output: 0 }
        @invalid_tool_count = 0
        @loop_context = @runtime_manager&.context&.extend

        begin
          target_model = model || @model
          opts = target_model ? { model: target_model } : {}
          opts[:tools] = @tool_registry.schemas unless plan_only

          mode = if plan_only
                   :plan
                 elsif goal_mode
                   :goal
                 else
                   :default
                 end

          system_prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
            mode: mode,
            tool_schemas: @tool_registry.schemas,
            config: @shell.respond_to?(:config) ? @shell.config : nil,
            commands: @shell.respond_to?(:commands) ? @shell.commands : nil,
            buffer_manager: @buffer_manager,
            snapshot_store: @snapshot_store,
            context_index: @context_index,
            lsp_manager: @lsp_manager,
            context_limit: @context_limit,
            root_dir: @root_dir,
            extra_context: initial_context
          )

          formatted_task = Rubik::Prompt::ContextBuilder.format_user_task(task_prompt)

          @history << { role: "system", content: system_prompt }

          # Inject prior dialogue turns if provided
          if conversation_history && !conversation_history.empty?
            conversation_history.each do |turn|
              r = turn[:role] || turn["role"]
              c = turn[:content] || turn["content"]
              next if r.nil? || c.nil? || c.to_s.strip.empty?

              @history << { role: r.to_s, content: c.to_s }
            end
          end

          @history << { role: "user", content: formatted_task }

          execute_steps(opts: opts, plan_only: plan_only)
        ensure
          @loop_context&.dispose
        end
      end

      def continue_loop(extra_steps = 20, plan_only: false)
        extend_budget(extra_steps)
        target_model = @model
        opts = target_model ? { model: target_model } : {}
        opts[:tools] = @tool_registry.schemas

        continuation_msg = "\n\n<step_budget_extended extra=\"#{extra_steps}\" new_max=\"#{@max_steps}\" current=\"#{@step_count}\" message=\"User approved extending step budget by #{extra_steps} steps. Continue working toward completion.\" />"
        if @history.last && @history.last.is_a?(Hash)
          @history.last[:content] = "#{@history.last[:content]}#{continuation_msg}"
        else
          @history << { role: "user", content: continuation_msg.strip }
        end
        execute_steps(opts: opts, plan_only: plan_only)
      end

      private

      def execute_steps(opts:, plan_only: false)
        @invalid_tool_count = 0
        warn_step = (@max_steps * @warn_at_ratio).ceil
        warned = false

        while @step_count < @max_steps
          @step_count += 1

          warned = evaluate_step_budget_warning!(warn_step, warned)
          evaluate_context_compaction!

          opts[:tools] = @tool_registry.schemas unless plan_only

          prov_name = if @provider.respond_to?(:name) && @provider.name
                        @provider.name
                      elsif @provider.class.name
                        @provider.class.name.split("::").last
                      else
                        "custom"
                      end

          @on_step&.call(
            type: :thinking,
            step: @step_count,
            max_steps: @max_steps,
            model: opts[:model] || @model,
            provider: prov_name
          )

          res = send_llm_request_with_recovery(opts)
          result = process_step_response(res, opts)
          return result if result
        end

        { ok: false, error: "Max steps budget exceeded (#{@max_steps})", steps: @step_count, tokens: @total_tokens, loop_instance: self }
      end

      def evaluate_step_budget_warning!(warn_step, warned)
        return warned if warned || @step_count < warn_step || @step_count >= @max_steps

        remaining = @max_steps - @step_count
        warning_xml = "\n\n<step_budget current=\"#{@step_count}\" max=\"#{@max_steps}\" remaining=\"#{remaining}\" alert=\"Step budget nearing limit (#{remaining} steps left). Please begin concluding your work, verify with tests/diagnostics, and call finish.\" />"
        if @history.last && @history.last.is_a?(Hash)
          @history.last[:content] = "#{@history.last[:content]}#{warning_xml}"
        else
          @history << { role: "user", content: warning_xml.strip }
        end
        @on_step&.call(type: :step_warning, current: @step_count, max: @max_steps, remaining: remaining)
        true
      end

      def evaluate_context_compaction!
        context_cfg = @config ? @config.fetch("context", {}) : {}
        if @context_limit && Rubik::Prompt::ContextCompactor.needs_compaction?(@history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg)
          @history = Rubik::Prompt::ContextCompactor.compact_history(@history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: context_cfg)
        end
      end

      def send_llm_request_with_recovery(opts)
        retry_attempted = false
        begin
          @provider.complete(@history, opts)
        rescue Rubik::LLM::ClientError, StandardError => e
          auto_recover = @config ? @config.fetch("context.auto_recover_on_overflow", true) : true
          if !retry_attempted && auto_recover && e.message =~ /context|context_length|maximum context|prompt is too long|token limit|too many tokens/i
            retry_attempted = true
            Rubik::Prompt::EmergencyCompactor.compact!(@history)
            @on_step&.call(type: :emergency_compact, reason: e.message, step: @step_count, max_steps: @max_steps)
            retry
          else
            raise e
          end
        end
      end

      def track_token_usage!(res)
        return unless res.respond_to?(:usage) && res.usage

        @total_tokens[:input] += res.usage[:input_tokens] || res.usage["input_tokens"] || 0
        @total_tokens[:output] += res.usage[:output_tokens] || res.usage["output_tokens"] || 0
      end

      def extract_and_normalize_tool_calls(res, text_resp)
        tool_calls = if res.respond_to?(:has_tool_calls?) && res.has_tool_calls?
                       res.tool_calls
                     else
                       parsed = parse_tool_call(text_resp)
                       parsed ? [parsed] : []
                     end

        # Ensure EVERY tool_call has a deterministic persistent id
        tool_calls.each_with_index do |tc, idx|
          tc["id"] ||= tc[:id] || "call_#{@step_count}_#{idx + 1}_#{rand(1000..9999)}"
        end
        tool_calls
      end

      def process_step_response(res, opts = {})
        track_token_usage!(res)

        text_resp = res.text.to_s.strip
        tool_calls = extract_and_normalize_tool_calls(res, text_resp)

        if tool_calls.empty?
          @history << { role: "assistant", content: text_resp } unless text_resp.empty?
          @on_step&.call(type: :message, content: text_resp, step: @step_count, max_steps: @max_steps)
          return { ok: true, output: text_resp, steps: @step_count, tokens: @total_tokens, loop_instance: self }
        end

        # Record assistant message with tool_calls in history
        @history << {
          role: "assistant",
          content: text_resp.empty? ? nil : text_resp,
          tool_calls: tool_calls
        }

        if !text_resp.empty? && tool_calls.none? { |tc|
             t_name = tc["tool"] || tc[:tool]
             resolved = @tool_registry.get(t_name)
             (resolved ? resolved.name : t_name.to_s.downcase) == "finish"
           }
          @on_step&.call(type: :llm_thought, content: text_resp, step: @step_count, max_steps: @max_steps)
        end

        execute_tool_calls(tool_calls, text_resp)
      end

      def execute_tool_calls(tool_calls, text_resp)
        auto_apply_mode = @shell&.config&.fetch("buffer.auto_apply", "manual").to_s.downcase

        tool_calls.each do |tool_call|
          result = execute_single_tool_call(tool_call, text_resp, auto_apply_mode)
          return result if result
        end

        nil
      end

      def execute_single_tool_call(tool_call, text_resp, auto_apply_mode)
        tool_name = tool_call["tool"] || tool_call[:tool]
        tool_args = tool_call["args"] || tool_call[:args] || {}
        call_id = tool_call["id"] || tool_call[:id] || "call_#{@step_count}_#{rand(1000..9999)}"

        tool_instance = @tool_registry.get(tool_name)
        canonical_name = tool_instance ? tool_instance.name : tool_name.to_s.downcase

        # Auto-apply buffer before running tests or shell commands on disk if configured
        if %w[run_command run_tests test lint].include?(canonical_name) && %w[on_test always].include?(auto_apply_mode)
          if @buffer_manager&.dirty?
            applied = @buffer_manager.apply!
            @shell&.sync_context_and_ast(applied)
            @on_step&.call(type: :auto_apply, reason: "pre_execution", files: applied, step: @step_count, max_steps: @max_steps)
          end
        end

        if canonical_name == "finish"
          return handle_finish_tool(tool_args, text_resp, auto_apply_mode)
        end

        if tool_instance
          execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
          nil
        else
          handle_invalid_tool(tool_name, call_id)
        end
      end

      def handle_finish_tool(tool_args, text_resp, auto_apply_mode)
        if %w[on_finish on_test always].include?(auto_apply_mode) && @buffer_manager&.dirty?
          applied = @buffer_manager.apply!
          @shell&.sync_context_and_ast(applied)
          @on_step&.call(type: :auto_apply, reason: "finish", files: applied, step: @step_count, max_steps: @max_steps)
        end

        clean_text_resp = clean_llm_text(text_resp)
        tool_msg = (tool_args["message"] || tool_args[:message]).to_s.strip

        final_msg = if !tool_msg.empty? && !%w[completed done finished ok task_completed].include?(tool_msg.downcase)
                      if !clean_text_resp.empty? && !clean_text_resp.include?(tool_msg) && !tool_msg.include?(clean_text_resp)
                        "#{clean_text_resp}\n\n#{tool_msg}"
                      elsif clean_text_resp.length > tool_msg.length && !clean_text_resp.include?("tool")
                        clean_text_resp
                      else
                        tool_msg
                      end
                    elsif !clean_text_resp.empty?
                      clean_text_resp
                    else
                      tool_msg.empty? ? "Completed" : tool_msg
                    end

        @on_step&.call(type: :finish, message: final_msg, step: @step_count, max_steps: @max_steps)
        { ok: true, output: final_msg, steps: @step_count, tokens: @total_tokens, loop_instance: self }
      end

      def execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
        @on_step&.call(type: :tool_call, tool: tool_name, args: tool_args, step: @step_count, max_steps: @max_steps, call_id: call_id)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        tool_result = begin
          raw_output = tool_instance.execute(tool_args)
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dur = ((t1 - t0) * 1000).round(1)

          max_chars = @shell&.config&.fetch("tools.max_output_chars", 12_000) || 12_000
          max_lines = @shell&.config&.fetch("tools.max_output_lines", 300) || 300
          trunc_strat = @shell&.config&.fetch("tools.truncation_strategy", "head_tail") || "head_tail"

          trunc_res = Rubik::Tools::Truncator.truncate(raw_output, max_chars: max_chars, max_lines: max_lines, strategy: trunc_strat)

          is_err = raw_output.is_a?(String) && (
            raw_output.start_with?("Error:") ||
            raw_output.start_with?("Error ") ||
            raw_output.start_with?("Usage:") ||
            raw_output.start_with?("Pre-flight verification failed") ||
            raw_output.start_with?("Bilinmeyen komut") ||
            raw_output.start_with?("Failed") ||
            raw_output.start_with?("Security blocked") ||
            raw_output.start_with?("Command error") ||
            raw_output.start_with?("[EXIT ") ||
            raw_output.start_with?("Test run [FAILED]") ||
            raw_output.start_with?("Lint [FAILED]")
          )

          Rubik::Tools::Result.new(
            tool_name: tool_name,
            call_id: call_id,
            status: is_err ? :error : :ok,
            error: is_err ? raw_output.lines.first.to_s.strip : nil,
            output: trunc_res[:text],
            duration_ms: dur,
            truncated: trunc_res[:truncated]
          )
        rescue StandardError => e
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dur = ((t1 - t0) * 1000).round(1)
          err_msg = "Error executing tool '#{tool_name}': #{e.class} - #{e.message}"
          Rubik::Tools::Result.new(
            tool_name: tool_name,
            call_id: call_id,
            status: :error,
            error: e.message,
            output: err_msg,
            duration_ms: dur
          )
        end

        if auto_apply_mode == "always" && @buffer_manager&.dirty?
          applied = @buffer_manager.apply!
          @shell&.sync_context_and_ast(applied)
        end

        # Real-time LSP In-Buffer Diagnostics feedback loop
        if tool_instance&.name == "write_file" && @lsp_manager&.enabled?
          written_file = tool_args["path"] || tool_args[:path]
          if written_file && @buffer_manager
            content = @buffer_manager.read(written_file)
            @lsp_manager.sync_buffer_file(written_file, content)
            if @lsp_manager.auto_diagnostics?
              diags = @lsp_manager.diagnostics_for(written_file)
              errors = diags.select { |d| d["severity"] == 1 }
              if !errors.empty?
                err_lines = errors.map { |e| "  • Line #{(e.dig('range', 'start', 'line') || 0) + 1}: #{e['message']}" }.join("\n")
                lsp_msg = "\n\n⚠️ [LSP Real-Time Compiler Diagnostics - #{errors.size} error(s)]:\n#{err_lines}\nPlease fix these compilation/type errors before proceeding."
                tool_result = Rubik::Tools::Result.new(
                  tool_name: tool_name,
                  call_id: call_id,
                  status: tool_result.status,
                  output: "#{tool_result.output}#{lsp_msg}",
                  duration_ms: tool_result.duration_ms,
                  truncated: tool_result.truncated
                )
              end
            end
          end
        end

        @on_step&.call(
          type: :tool_result,
          tool: tool_name,
          output: tool_result.output,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          step: @step_count,
          max_steps: @max_steps,
          call_id: call_id,
          line_count: tool_result.output.to_s.lines.size,
          byte_size: tool_result.output.to_s.bytesize,
          tokens: @total_tokens
        )

        @history << {
          role: "tool",
          tool_call_id: call_id,
          tool_name: tool_name,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          content: tool_result.to_xml
        }
        @invalid_tool_count = 0
        tool_result
      end

      def handle_invalid_tool(tool_name, call_id)
        @invalid_tool_count += 1
        if @invalid_tool_count >= 2
          return { ok: false, error: "Repeated invalid tool call '#{tool_name}'", steps: @step_count, tokens: @total_tokens, loop_instance: self }
        end

        err_result = Rubik::Tools::Result.new(
          tool_name: tool_name,
          call_id: call_id,
          status: :error,
          error: "Tool '#{tool_name}' does not exist.",
          output: "Error: Tool '#{tool_name}' does not exist. Please check available tools.",
          duration_ms: 0.0
        )
        @history << {
          role: "tool",
          tool_call_id: call_id,
          tool_name: tool_name,
          status: :error,
          duration_ms: 0.0,
          content: err_result.to_xml
        }
        nil
      end

      def parse_tool_call(text)
        cleaned = text.to_s.gsub("\\n", "\n")
        if cleaned.include?("```json")
          json_str = cleaned.split("```json").last.split("```").first.strip
          JSON.parse(json_str)
        elsif cleaned.start_with?("{") && cleaned.end_with?("}")
          JSON.parse(cleaned)
        else
          nil
        end
      rescue StandardError
        nil
      end

      def clean_llm_text(text)
        str = text.to_s.strip
        return "" if str.empty?

        # If whole text is raw JSON tool call e.g. {"tool": "finish", "args": {...}}
        if str.start_with?("{") && str.end_with?("}")
          parsed = (JSON.parse(str) rescue nil)
          return "" if parsed.is_a?(Hash) && (parsed.key?("tool") || parsed.key?(:tool))
        end

        # Strip ```json ... ``` blocks
        str.gsub(/```(?:json)?\s*\{.*?\}\s*```/m, "").strip
      end
    end
  end
end
