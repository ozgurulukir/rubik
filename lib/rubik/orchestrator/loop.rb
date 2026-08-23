# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    class Loop
      attr_reader :max_steps, :step_count, :history, :model, :total_tokens

      def initialize(provider:, tool_registry:, max_steps: 15, model: nil, on_step: nil)
        @provider = provider
        @tool_registry = tool_registry
        @max_steps = max_steps
        @model = model
        @on_step = on_step
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

        system_prompt = if plan_only
          <<~SYS
            You are Rubik AI Coding Agent in PLAN-ONLY mode.
            Analyze the user's task and output a concise, numbered step-by-step implementation plan.
            Do NOT call write tools or execute commands yet. Specify what files will be created or edited.

            Available tools for execution:
            #{JSON.dump(@tool_registry.schemas)}

            Context:
            #{initial_context}
          SYS
        elsif goal_mode
          <<~SYS
            You are Rubik AI Coding Agent in AUTONOMOUS GOAL mode.
            You must independently fulfill the goal:
            1. Formulate a sub-task strategy.
            2. Use `list_files`, `search_symbols`, `read_file` to understand the codebase.
            3. Use `write_file` to prepare changes in the in-memory buffer.
            4. Use `run_tests` to verify your changes.
            5. If tests fail, inspect diagnostics and fix your code until all tests pass.
            6. Call `finish` only when the goal is verified and complete.

            You can call tools by outputting a JSON block:
            ```json
            { "tool": "tool_name", "args": { ... } }
            ```
            Available tools:
            #{JSON.dump(@tool_registry.schemas)}

            Context:
            #{initial_context}
          SYS
        else
          <<~SYS
            You are Rubik AI Coding Agent.
            You can call tools by outputting a JSON block:
            ```json
            { "tool": "tool_name", "args": { ... } }
            ```
            Available tools:
            #{JSON.dump(@tool_registry.schemas)}

            Context:
            #{initial_context}
          SYS
        end

        @history << { role: "system", content: system_prompt }
        @history << { role: "user", content: task_prompt }

        invalid_tool_count = 0

        while @step_count < @max_steps
          @step_count += 1
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

            if tool_name == "finish"
              final_msg = tool_args["message"] || tool_args[:message] || "Completed"
              @on_step&.call(type: :finish, message: final_msg, step: @step_count)
              return { ok: true, output: final_msg, steps: @step_count, tokens: @total_tokens }
            end

            tool_instance = @tool_registry.get(tool_name)
            if tool_instance
              @on_step&.call(type: :tool_call, tool: tool_name, args: tool_args, step: @step_count)
              tool_output = tool_instance.execute(tool_args)
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
