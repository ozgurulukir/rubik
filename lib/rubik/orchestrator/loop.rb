# frozen_string_literal: true

require "json"
require_relative "../prompt"
require_relative "activity_log"
require_relative "step_executor"
require_relative "budget_manager"
require_relative "stream_manager"

module Rubik
  module Orchestrator
    class Loop
      attr_accessor :history, :invalid_tool_count, :last_turn_streamed, :empty_response_count, :context_warning_emitted
      attr_reader :max_steps, :step_count, :model, :total_tokens, :warn_at_ratio, :runtime_manager, :loop_context, :context_limit, :max_output_tokens, :config
      # Collaborator-facing state (Plan 54 D-5): loop state physically stays on Loop;
      # extracted collaborators reach it through these accessors.
      attr_reader :provider, :on_step, :tool_registry, :shell, :buffer_manager, :lsp_manager, :step_executor, :budget_manager, :stream_manager, :activity

      def initialize(provider:, tool_registry:, max_steps: 40, warn_at_ratio: 0.75, model: nil, on_step: nil, shell: nil, context_limit: nil,
                     max_output_tokens: nil)
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
        @last_turn_streamed = false
        @empty_response_count = 0
        @context_warning_emitted = false
        # Plan 61 D-15: per-run activity ledger feeding the turn summary.
        @activity = ActivityLog.new
        @step_executor = StepExecutor.new(self)
        @budget_manager = BudgetManager.new(self)
        @stream_manager = StreamManager.new(self)
      end

      def extend_budget(extra_steps)
        @max_steps += extra_steps.to_i
      end

      def run(task_prompt, model: nil, plan_only: false, goal_mode: false, initial_context: nil, conversation_history: [])
        @step_count = 0
        @history = []
        @total_tokens = { input: 0, output: 0 }
        @invalid_tool_count = 0
        @empty_response_count = 0
        @context_warning_emitted = false
        @activity&.reset!
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

        # Plan 61 D-14: notifications travel as their own user message —
        # appending to @history.last may target a tool result or a
        # content-less assistant message, which provider formatters then
        # mangle.
        continuation_msg = "<step_budget_extended extra=\"#{extra_steps}\" new_max=\"#{@max_steps}\" " \
                           "current=\"#{@step_count}\" " \
                           "message=\"User approved extending step budget by #{extra_steps} steps. " \
                           "Continue working toward completion.\" />"
        @history << { role: "user", content: continuation_msg }
        execute_steps(opts: opts, plan_only: plan_only)
      end

      private

      def execute_steps(opts:, plan_only: false)
        @invalid_tool_count = 0
        @empty_response_count = 0
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
        @budget_manager.evaluate_step_budget_warning!(warn_step, warned)
      end

      def evaluate_context_compaction!
        @budget_manager.evaluate_context_compaction!
      end

      def send_llm_request_with_recovery(opts)
        streaming_enabled = if opts.key?(:stream)
                              opts[:stream] == true
                            elsif @config
                              @config.fetch("llm.stream", true) != false
                            else
                              true
                            end

        # Plan 61 D-1/D-3: the wire request must share the compaction math's
        # assumptions. Ollama needs context_limit (sent as num_ctx) or its
        # server silently clips the prompt head to the model default; strict
        # providers need max_tokens or output falls back to tiny defaults
        # (e.g. Anthropic's 1024).
        effective_opts = opts.key?(:on_retry) ? opts.dup : opts.merge(on_retry: @stream_manager.llm_retry_notifier)
        effective_opts[:context_limit] = @context_limit if @context_limit
        effective_opts[:max_tokens] = @max_output_tokens if @max_output_tokens&.positive?

        if streaming_enabled && @provider.respond_to?(:stream_chat)
          @stream_manager.execute_streaming_request(effective_opts)
        else
          execute_batch_request(effective_opts)
        end
      end

      def execute_batch_request(opts)
        retry_attempted = false
        @last_turn_streamed = false
        begin
          @provider.complete(@history, opts)
        rescue StandardError => e
          auto_recover = @config ? @config.fetch("context.auto_recover_on_overflow", true) : true
          unless !retry_attempted && auto_recover && e.message =~ /context|context_length|maximum context|prompt is too long|token limit|too many tokens/i
            raise e
          end

          retry_attempted = true
          Rubik::Prompt::EmergencyCompactor.compact!(@history)
          @on_step&.call(type: :emergency_compact, reason: e.message, step: @step_count, max_steps: @max_steps)
          retry
        end
      end

      def track_token_usage!(res)
        @budget_manager.track_token_usage!(res)
      end

      def extract_and_normalize_tool_calls(res, text_resp)
        tool_calls = if res.respond_to?(:tool_calls?) && res.tool_calls?
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

      def process_step_response(res, _opts = {})
        track_token_usage!(res)

        text_resp = res.text.to_s.strip
        tool_calls = extract_and_normalize_tool_calls(res, text_resp)

        if tool_calls.empty?
          # Plan 61 D-11: an empty reply used to end the turn silently with
          # output:"" — one nudge keeps the loop going; two in a row bail out.
          if text_resp.empty?
            @empty_response_count += 1
            if @empty_response_count >= 2
              return { ok: false, error: "Empty response from model", steps: @step_count, tokens: @total_tokens, streamed: @last_turn_streamed == true,
                       loop_instance: self }
            end

            @history << { role: "user", content: "Your last response was empty. Continue the task or call the finish tool." }
            return nil
          end

          @empty_response_count = 0
          @history << { role: "assistant", content: text_resp }
          @on_step&.call(type: :message, content: text_resp, step: @step_count, max_steps: @max_steps)
          return { ok: true, output: text_resp, steps: @step_count, tokens: @total_tokens, streamed: @last_turn_streamed == true, loop_instance: self }
        end

        # Record assistant message with tool_calls in history
        @empty_response_count = 0
        @history << {
          role: "assistant",
          content: text_resp.empty? ? nil : text_resp,
          tool_calls: tool_calls
        }

        if !text_resp.empty? && tool_calls.none? do |tc|
             t_name = tc["tool"] || tc[:tool]
             resolved = @tool_registry.get(t_name)
             (resolved ? resolved.name : t_name.to_s.downcase) == "finish"
           end
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
        @step_executor.execute_single_tool_call(tool_call, text_resp, auto_apply_mode)
      end

      def handle_finish_tool(tool_args, text_resp, auto_apply_mode)
        @step_executor.handle_finish_tool(tool_args, text_resp, auto_apply_mode)
      end

      def execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
        @step_executor.execute_registered_tool(tool_instance, tool_name, tool_args, call_id, auto_apply_mode)
      end

      def handle_invalid_tool(tool_name, call_id)
        @step_executor.handle_invalid_tool(tool_name, call_id)
      end

      def parse_tool_call(text)
        cleaned = text.to_s.gsub("\\n", "\n")
        if cleaned.include?("```json")
          json_str = cleaned.split("```json").last.split("```").first.strip
          JSON.parse(json_str)
        elsif cleaned.start_with?("{") && cleaned.end_with?("}")
          JSON.parse(cleaned)
        end
      rescue StandardError
        nil
      end
    end
  end
end
