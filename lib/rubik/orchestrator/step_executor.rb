# frozen_string_literal: true

require_relative "finish_message_selector"
require_relative "auto_apply"
require_relative "tool_call_id"

module Rubik
  module Orchestrator
    # Dispatches a single normalized tool call against the registry (Plan 54
    # D-6). The executor is a stateless collaborator: every piece of loop
    # state (history, counters, shell wiring, streamed flag) physically stays
    # on Loop and is reached through the ShellDeps façade (Plan 87 E-1), so
    # send-based tests and the res[:streamed] contract keep working unchanged.
    class StepExecutor
      ERROR_PREFIXES = [
        "-- ",
        "Error:",
        "Error ",
        "Usage:",
        "Pre-flight verification failed",
        "Bilinmeyen komut",
        "Failed",
        "Security blocked",
        "Command error",
        "[EXIT ",
        "Test run [FAILED]",
        "Lint [FAILED]",
        "[CONFLICT]",
        "[CONFLICT "
      ].freeze

      # Plan 87 E-1: state is reached through the ShellDeps façade. Accepts a
      # bare loop for compatibility with existing test doubles (wrapped).
      def initialize(loop_or_deps)
        @deps = ShellDeps.wrap(loop_or_deps)
      end

      def execute_single_tool_call(tool_call, text_resp, auto_apply_mode = nil)
        tool_name = tool_call["tool"] || tool_call[:tool]
        tool_args = tool_call["args"] || tool_call[:args] || {}
        call_id = tool_call["id"] || tool_call[:id] || ToolCallId.mint(@deps.step_count, unique: true)

        tool_instance = @deps.respond_to?(:tool_registry) && @deps.tool_registry ? @deps.tool_registry.get(tool_name) : nil
        canonical_name = tool_instance ? tool_instance.name : tool_name.to_s.downcase

        # Auto-apply buffer before running tests or shell commands on disk if
        # configured (decision: AutoApply; explicit mode = test injection seam)
        if AutoApply.apply?(@deps.config, trigger: :pre_execution, tool: canonical_name, mode: auto_apply_mode) && @deps.buffer_manager&.dirty?
          applied = AutoApply.apply_and_sync(@deps.buffer_manager, @deps.shell)
          @deps.on_step&.call(type: :auto_apply, reason: "pre_execution", files: applied, step: @deps.step_count, max_steps: @deps.max_steps)
        end

        return handle_finish_tool(tool_args, text_resp, auto_apply_mode) if canonical_name == "finish"

        if tool_instance
          execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
          nil
        else
          handle_invalid_tool(tool_name, call_id)
        end
      end

      def handle_finish_tool(tool_args, text_resp, auto_apply_mode = nil)
        if AutoApply.apply?(@deps.config, trigger: :finish, mode: auto_apply_mode) && @deps.buffer_manager&.dirty?
          applied = AutoApply.apply_and_sync(@deps.buffer_manager, @deps.shell)
          @deps.on_step&.call(type: :auto_apply, reason: "finish", files: applied, step: @deps.step_count, max_steps: @deps.max_steps)
        end

        clean_text_resp = clean_llm_text(text_resp)
        tool_msg = (tool_args["message"] || tool_args[:message]).to_s.strip

        # Review Finding 5: message-selection heuristic extracted to
        # FinishMessageSelector (documented, named constants, unit-pinned).
        final_msg = FinishMessageSelector.select(clean_text_resp, tool_msg)

        # Plan 61: the marker must know where the content went — streamed
        # turns already printed it above, batch turns render right below.
        @deps.on_step&.call(type: :finish, message: final_msg, streamed: @deps.last_turn_streamed == true,
                            step: @deps.step_count, max_steps: @deps.max_steps)
        # streamed must reflect the FINISHING turn's reality: its text may
        # have been streamed as chunks before the finish call. A hardcoded
        # false made the free-text render treat an already-printed answer as
        # unprinted and print it a second time.
        { ok: true, output: final_msg, steps: @deps.step_count, tokens: @deps.total_tokens,
          streamed: @deps.last_turn_streamed == true, loop_instance: @deps.loop_instance }
      end

      def execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode = nil)
        @deps.on_step&.call(type: :tool_call, tool: tool_name, args: tool_args, step: @deps.step_count, max_steps: @deps.max_steps, call_id: call_id)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        tool_result = begin
          raw_output = tool_instance.execute(tool_args)
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          dur = ((t1 - t0) * 1000).round(1)

          max_chars = @deps.shell&.config&.fetch("tools.max_output_chars", 12_000) || 12_000
          max_lines = @deps.shell&.config&.fetch("tools.max_output_lines", 300) || 300
          trunc_strat = @deps.shell&.config&.fetch("tools.truncation_strategy", "head_tail") || "head_tail"

          if raw_output.is_a?(Rubik::Tools::Result)
            trunc_res = Rubik::Tools::Truncator.truncate(raw_output.output, max_chars: max_chars, max_lines: max_lines, strategy: trunc_strat)
            effective_dur = raw_output.duration_ms.positive? ? raw_output.duration_ms : dur
            first_line = raw_output.output.lines.first.to_s.strip
            first_line = nil if first_line.empty?
            Rubik::Tools::Result.new(
              tool_name: raw_output.tool_name.to_s.empty? ? tool_name : raw_output.tool_name,
              call_id: raw_output.call_id.to_s.empty? ? call_id : raw_output.call_id,
              status: raw_output.status,
              error: raw_output.error || (raw_output.error? ? first_line : nil),
              exit_code: raw_output.exit_code,
              output: trunc_res[:text],
              duration_ms: effective_dur,
              truncated: raw_output.truncated || trunc_res[:truncated],
              metadata: raw_output.metadata
            )
          elsif raw_output.respond_to?(:status) && raw_output.respond_to?(:output)
            out_str = raw_output.output.to_s
            trunc_res = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: trunc_strat)
            st = raw_output.status.to_sym
            first_line = out_str.lines.first.to_s.strip
            first_line = nil if first_line.empty?
            err = (raw_output.respond_to?(:error) && raw_output.error) || (st == :error ? first_line : nil)
            Rubik::Tools::Result.new(
              tool_name: tool_name,
              call_id: call_id,
              status: st,
              error: err,
              output: trunc_res[:text],
              duration_ms: dur,
              truncated: trunc_res[:truncated]
            )
          else
            out_str = raw_output.to_s
            trunc_res = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars, max_lines: max_lines, strategy: trunc_strat)

            is_err = if raw_output.respond_to?(:error?)
                       raw_output.error?
                     elsif raw_output.respond_to?(:failed?)
                       raw_output.failed?
                     elsif raw_output.is_a?(String)
                       ERROR_PREFIXES.any? { |pfx| raw_output.start_with?(pfx) }
                     else
                       false
                     end

            first_line = out_str.lines.first.to_s.strip
            first_line = nil if first_line.empty?

            Rubik::Tools::Result.new(
              tool_name: tool_name,
              call_id: call_id,
              status: is_err ? :error : :ok,
              error: is_err ? first_line : nil,
              output: trunc_res[:text],
              duration_ms: dur,
              truncated: trunc_res[:truncated]
            )
          end
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

        # always-mode flush after every tool — was historically silent; the
        # post_tool event makes the disk write visible like every other apply
        if AutoApply.apply?(@deps.config, trigger: :post_tool, mode: auto_apply_mode) && @deps.buffer_manager&.dirty?
          applied = AutoApply.apply_and_sync(@deps.buffer_manager, @deps.shell)
          @deps.on_step&.call(type: :auto_apply, reason: "post_tool", files: applied, step: @deps.step_count, max_steps: @deps.max_steps)
        end

        # Real-time LSP In-Buffer Diagnostics feedback loop (Plan 56 D-5)
        if tool_result.status == :ok && ["write_file", "replace_file_content"].include?(tool_instance&.name) && @deps.lsp_manager&.enabled?
          written_file = tool_args["path"] || tool_args[:path]
          if written_file && @deps.buffer_manager
            begin
              content = @deps.buffer_manager.read(written_file)
              synced = @deps.lsp_manager.sync_buffer_file(written_file, content)
              if synced && @deps.lsp_manager.auto_diagnostics?
                sleep 0.05
                diags = @deps.lsp_manager.diagnostics_for(written_file)
                errors = diags.select { |d| d["severity"] == 1 }
                unless errors.empty?
                  err_lines = errors.map { |e| "  • Line #{(e.dig('range', 'start', 'line') || 0) + 1}: #{e['message']}" }.join("\n")
                  lsp_msg = "\n\n⚠️ [LSP Real-Time Compiler Diagnostics - #{errors.size} error(s)]:\n#{err_lines}\n" \
                            "Please fix these compilation/type errors before proceeding."
                  tool_result = Rubik::Tools::Result.new(
                    tool_name: tool_name, call_id: call_id, status: tool_result.status,
                    output: "#{tool_result.output}#{lsp_msg}", duration_ms: tool_result.duration_ms,
                    truncated: tool_result.truncated
                  )
                end
              end
            rescue StandardError => e
              # Loop exposes no logger; the old @loop.logger&.debug raised
              # NoMethodError from inside this rescue itself (fresh-eye
              # review, Plan 87). warn keeps the failure visible on stderr;
              # ANSI stripping keeps LSP-server-controlled messages from
              # injecting terminal escape sequences (red-team E1).
              warn("LSP sync skipped: #{e.message.gsub(/\e\[[0-9;]*[A-Za-z]/, '')}")
            end
          end
        end

        @deps.on_step&.call(
          type: :tool_result,
          tool: tool_name,
          output: tool_result.output,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          step: @deps.step_count,
          max_steps: @deps.max_steps,
          call_id: call_id,
          line_count: tool_result.output.to_s.lines.size,
          byte_size: tool_result.output.to_s.bytesize,
          tokens: @deps.total_tokens
        )

        @deps.history << {
          role: "tool",
          tool_call_id: call_id,
          tool_name: tool_name,
          status: tool_result.status,
          duration_ms: tool_result.duration_ms,
          content: tool_result.to_xml
        }
        @deps.activity.record(tool_name, tool_args, tool_result.status) if @deps.respond_to?(:activity)
        @deps.reset_invalid_tools!
        tool_result
      end

      def handle_invalid_tool(tool_name, call_id)
        @deps.record_invalid_tool!
        @deps.activity.record(tool_name, {}, :error) if @deps.respond_to?(:activity)
        if @deps.invalid_tool_count >= 2
          return { ok: false, error: "Repeated invalid tool call '#{tool_name}'", steps: @deps.step_count,
                   tokens: @deps.total_tokens, loop_instance: @deps.loop_instance }
        end

        registry = @deps.respond_to?(:tool_registry) && @deps.tool_registry
        all_tool_names = registry ? registry.list.map(&:name) : []
        all_lookup_names = if registry
                             (registry.list.map(&:name) + (registry.respond_to?(:aliases_map) ? registry.aliases_map.keys : [])).uniq
                           else
                             []
                           end

        matched_candidates = Rubik::Tools::FuzzyMatcher.best_matches(tool_name, all_lookup_names)
        candidate_tools = matched_candidates.map { |c| registry&.get(c)&.name || c }.uniq
        diagnostic_msg = Rubik::Tools::DiagnosticReporter.render_unknown_tool(tool_name, candidate_tools: candidate_tools, all_tools: all_tool_names)

        err_result = Rubik::Tools::Result.new(
          tool_name: tool_name,
          call_id: call_id,
          status: :error,
          error: "Tool '#{tool_name}' does not exist.",
          output: diagnostic_msg,
          duration_ms: 0.0
        )
        @deps.history << {
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
          parsed = begin
            JSON.parse(str)
          rescue JSON::ParserError
            nil
          end
          return "" if parsed.is_a?(Hash) && (parsed.key?("tool") || parsed.key?(:tool))
          # A {...} envelope that failed to parse is itself a malformed tool
          # call; swallow it to "" rather than leaking the raw text as content.
          return "" if parsed.nil?
        end

        # Strip ```json ... ``` blocks
        str.gsub(/```(?:json)?\s*\{.*?\}\s*```/m, "").strip
      end
    end
  end
end
