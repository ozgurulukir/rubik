# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    class Loop
      attr_reader :max_steps, :step_count, :history, :model, :total_tokens

      def initialize(provider:, tool_registry:, max_steps: 15, model: nil, on_step: nil, shell: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, lsp_manager: nil, root_dir: Dir.pwd)
        @provider = provider
        @tool_registry = tool_registry
        @max_steps = max_steps
        @model = model
        @on_step = on_step
        @shell = shell
        @buffer_manager = buffer_manager
        @snapshot_store = snapshot_store
        @context_index = context_index
        @lsp_manager = lsp_manager
        @root_dir = File.expand_path(root_dir)
        @step_count = 0
        @history = []
        @total_tokens = { input: 0, output: 0 }
      end

      def run(task_prompt, initial_context = "", model: nil, plan_only: false, goal_mode: false)
        @step_count = 0
        @history.clear
        @total_tokens = { input: 0, output: 0 }
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
          shell: @shell,
          buffer_manager: @buffer_manager,
          snapshot_store: @snapshot_store,
          context_index: @context_index,
          lsp_manager: @lsp_manager,
          root_dir: @root_dir,
          extra_context: initial_context
        )

        formatted_task = Rubik::Prompt::ContextBuilder.format_user_task(task_prompt)

        @history << { role: "system", content: system_prompt }
        @history << { role: "user", content: formatted_task }

        invalid_tool_count = 0

        while @step_count < @max_steps
          @step_count += 1
          opts[:tools] = @tool_registry.schemas unless plan_only
          res = @provider.complete(@history, opts)
          if res.respond_to?(:usage) && res.usage
            @total_tokens[:input] += res.usage[:input_tokens] || res.usage["input_tokens"] || 0
            @total_tokens[:output] += res.usage[:output_tokens] || res.usage["output_tokens"] || 0
          end

          text_resp = res.text.to_s.strip
          @history << { role: "assistant", content: text_resp } unless text_resp.empty?

          tool_calls = if res.respond_to?(:has_tool_calls?) && res.has_tool_calls?
            res.tool_calls
          else
            parsed = parse_tool_call(text_resp)
            parsed ? [parsed] : []
          end

          if tool_calls.empty?
            @on_step&.call(type: :message, content: text_resp, step: @step_count)
            return { ok: true, output: text_resp, steps: @step_count, tokens: @total_tokens }
          end

          tool_calls.each do |tool_call|
            tool_name = tool_call["tool"] || tool_call[:tool]
            tool_args = tool_call["args"] || tool_call[:args] || {}
            auto_apply_mode = @shell&.config&.fetch("buffer.auto_apply", "manual").to_s.downcase

            # Auto-apply buffer before running tests or shell commands on disk if configured
            if %w[run_command run_tests test lint].include?(tool_name) && %w[on_test always].include?(auto_apply_mode)
              if @buffer_manager&.dirty?
                applied = @buffer_manager.apply!
                @shell&.sync_context_and_ast(applied)
                @on_step&.call(type: :auto_apply, reason: "pre_execution", files: applied, step: @step_count)
              end
            end

            if tool_name == "finish"
              if %w[on_finish on_test always].include?(auto_apply_mode) && @buffer_manager&.dirty?
                applied = @buffer_manager.apply!
                @shell&.sync_context_and_ast(applied)
                @on_step&.call(type: :auto_apply, reason: "finish", files: applied, step: @step_count)
              end

              final_msg = tool_args["message"] || tool_args[:message] || "Completed"
              @on_step&.call(type: :finish, message: final_msg, step: @step_count)
              return { ok: true, output: final_msg, steps: @step_count, tokens: @total_tokens }
            end

            tool_instance = @tool_registry.get(tool_name)
            if tool_instance
              @on_step&.call(type: :tool_call, tool: tool_name, args: tool_args, step: @step_count)
              tool_output = tool_instance.execute(tool_args)

              if auto_apply_mode == "always" && @buffer_manager&.dirty?
                applied = @buffer_manager.apply!
                @shell&.sync_context_and_ast(applied)
              end

              # Real-time LSP In-Buffer Diagnostics feedback loop
              if tool_name == "write_file" && @lsp_manager&.enabled?
                written_file = tool_args["path"] || tool_args[:path]
                if written_file && @buffer_manager
                  content = @buffer_manager.read(written_file)
                  @lsp_manager.sync_buffer_file(written_file, content)
                  if @lsp_manager.auto_diagnostics?
                    diags = @lsp_manager.diagnostics_for(written_file)
                    errors = diags.select { |d| d["severity"] == 1 }
                    if !errors.empty?
                      err_lines = errors.map { |e| "  • Line #{(e.dig('range', 'start', 'line') || 0) + 1}: #{e['message']}" }.join("\n")
                      tool_output = "#{tool_output}\n\n⚠️ [LSP Real-Time Compiler Diagnostics - #{errors.size} error(s)]:\n#{err_lines}\nPlease fix these compilation/type errors before proceeding."
                    end
                  end
                end
              end

              @on_step&.call(type: :tool_result, tool: tool_name, output: tool_output, step: @step_count)
              @history << { role: "user", content: "Tool #{tool_name} output:\n#{tool_output}" }
              invalid_tool_count = 0
            else
              invalid_tool_count += 1
              if invalid_tool_count >= 2
                return { ok: false, error: "Repeated invalid tool call '#{tool_name}'", steps: @step_count, tokens: @total_tokens }
              end
              @history << { role: "user", content: "Error: Tool '#{tool_name}' does not exist." }
            end
          end
        end

        { ok: false, error: "Max steps budget exceeded (#{@max_steps})", steps: @step_count, tokens: @total_tokens }
      end

      private

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
    end
  end
end
