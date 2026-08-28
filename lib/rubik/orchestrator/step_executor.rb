# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Dispatches a single normalized tool call against the registry (Plan 54
    # D-6). The executor is a stateless collaborator: every piece of loop
    # state (history, counters, shell wiring, streamed flag) physically stays
    # on Loop and is reached through its accessors, so send-based tests and
    # the res[:streamed] contract keep working unchanged.
    class StepExecutor
      def initialize(loop)
        @loop = loop
      end

      def execute_single_tool_call(tool_call, text_resp, auto_apply_mode)
        tool_name = tool_call["tool"] || tool_call[:tool]
        tool_args = tool_call["args"] || tool_call[:args] || {}
        call_id = tool_call["id"] || tool_call[:id] || "call_#{@loop.step_count}_#{rand(1000..9999)}"

        tool_instance = @loop.tool_registry.get(tool_name)
        canonical_name = tool_instance ? tool_instance.name : tool_name.to_s.downcase

        # Auto-apply buffer before running tests or shell commands on disk if configured
        if %w[run_command run_tests test lint].include?(canonical_name) && %w[on_test always].include?(auto_apply_mode)
          if @loop.buffer_manager&.dirty?
            applied = @loop.buffer_manager.apply!
            @loop.shell&.sync_context_and_ast(applied)
            @loop.on_step&.call(type: :auto_apply, reason: "pre_execution", files: applied, step: @loop.step_count, max_steps: @loop.max_steps)
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
        if %w[on_finish on_test always].include?(auto_apply_mode) && @loop.buffer_manager&.dirty?
          applied = @loop.buffer_manager.apply!
          @loop.shell&.sync_context_and_ast(applied)
          @loop.on_step&.call(type: :auto_apply, reason: "finish", files: applied, step: @loop.step_count, max_steps: @loop.max_steps)
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

        @loop.on_step&.call(type: :finish, message: final_msg, step: @loop.step_count, max_steps: @loop.max_steps)
        # streamed must reflect the FINISHING turn's reality: its text may
        # have been streamed as chunks before the finish call. A hardcoded
        # false made the free-text render treat an already-printed answer as
        # unprinted and print it a second time.
        { ok: true, output: final_msg, steps: @loop.step_count, tokens: @loop.total_tokens, streamed: @loop.last_turn_streamed == true, loop_instance: @loop }
      end

      def execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
        @loop.on_step&.call(type: :tool_call, tool: tool_name, args: tool_args, step: @loop.step_count, max_steps: @loop.max_steps, call_id: call_id)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        tool_result = begin
          raw_output = tool_instance.execute(tool_args)
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dur = ((t1 - t0) * 1000).round(1)

          max_chars = @loop.shell&.config&.fetch("tools.max_output_chars", 12_000) || 12_000
          max_lines = @loop.shell&.config&.fetch("tools.max_output_lines", 300) || 300
          trunc_strat = @loop.shell&.config&.fetch("tools.truncation_strategy", "head_tail") || "head_tail"

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

        if auto_apply_mode == "always" && @loop.buffer_manager&.dirty?
          applied = @loop.buffer_manager.apply!
          @loop.shell&.sync_context_and_ast(applied)
        end

        # Real-time LSP In-Buffer Diagnostics feedback loop
        if tool_instance&.name == "write_file" && @loop.lsp_manager&.enabled?
          written_file = tool_args["path"] || tool_args[:path]
          if written_file && @loop.buffer_manager
            content = @loop.buffer_manager.read(written_file)
            @loop.lsp_manager.sync_buffer_file(written_file, content)
            if @loop.lsp_manager.auto_diagnostics?
              diags = @loop.lsp_manager.diagnostics_for(written_file)
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

        @loop.on_step&.call(
          type: :tool_result,
          tool: tool_name,
          output: tool_result.output,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          step: @loop.step_count,
          max_steps: @loop.max_steps,
          call_id: call_id,
          line_count: tool_result.output.to_s.lines.size,
          byte_size: tool_result.output.to_s.bytesize,
          tokens: @loop.total_tokens
        )

        @loop.history << {
          role: "tool",
          tool_call_id: call_id,
          tool_name: tool_name,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          content: tool_result.to_xml
        }
        @loop.invalid_tool_count = 0
        tool_result
      end

      def handle_invalid_tool(tool_name, call_id)
        @loop.invalid_tool_count += 1
        if @loop.invalid_tool_count >= 2
          return { ok: false, error: "Repeated invalid tool call '#{tool_name}'", steps: @loop.step_count, tokens: @loop.total_tokens, loop_instance: @loop }
        end

        err_result = Rubik::Tools::Result.new(
          tool_name: tool_name,
          call_id: call_id,
          status: :error,
          error: "Tool '#{tool_name}' does not exist.",
          output: "Error: Tool '#{tool_name}' does not exist. Please check available tools.",
          duration_ms: 0.0
        )
        @loop.history << {
          role: "tool",
          tool_call_id: call_id,
          tool_name: tool_name,
          status: :error,
          duration_ms: 0.0,
          content: err_result.to_xml
        }
        nil
      end

      private

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
