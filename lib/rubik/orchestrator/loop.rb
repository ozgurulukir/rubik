# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    class Loop
      attr_reader :max_steps, :step_count, :history, :model

      def initialize(provider:, tool_registry:, max_steps: 15, model: nil)
        @provider = provider
        @tool_registry = tool_registry
        @max_steps = max_steps
        @model = model
        @step_count = 0
        @history = []
      end

      def run(task_prompt, initial_context = "", model: nil)
        @step_count = 0
        @history.clear
        target_model = model || @model
        opts = target_model ? { model: target_model } : {}

        system_prompt = <<~SYS
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

        @history << { role: "system", content: system_prompt }
        @history << { role: "user", content: task_prompt }

        invalid_tool_count = 0

        while @step_count < @max_steps
          @step_count += 1
          res = @provider.complete(@history, opts)
          text_resp = res.text.strip
          @history << { role: "assistant", content: text_resp }

          tool_call = parse_tool_call(text_resp)
          unless tool_call
            return { ok: true, output: text_resp, steps: @step_count }
          end

          tool_name = tool_call["tool"]
          tool_args = tool_call["args"] || {}

          if tool_name == "finish"
            final_msg = tool_args["message"] || "Completed"
            return { ok: true, output: final_msg, steps: @step_count }
          end

          tool_instance = @tool_registry.get(tool_name)
          if tool_instance
            tool_output = tool_instance.execute(tool_args)
            @history << { role: "user", content: "Tool #{tool_name} output:\n#{tool_output}" }
            invalid_tool_count = 0
          else
            invalid_tool_count += 1
            if invalid_tool_count >= 2
              return { ok: false, error: "Repeated invalid tool call '#{tool_name}'", steps: @step_count }
            end
            @history << { role: "user", content: "Error: Tool '#{tool_name}' does not exist." }
          end
        end

        { ok: false, error: "Max steps budget exceeded (#{@max_steps})", steps: @step_count }
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
