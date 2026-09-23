# frozen_string_literal: true

require "json"
require_relative "../prompt"
require_relative "activity_log"
require_relative "shell_deps"
require_relative "step_executor"
require_relative "budget_manager"
require_relative "stream_manager"
require_relative "provider_resolver"
require_relative "provider_recovery"
require_relative "continuation_manager"
require_relative "subagent_notice_inbox"
require_relative "subagent/notices"

module Rubik
  module Orchestrator
    class Loop
      attr_accessor :history, :invalid_tool_count, :last_turn_streamed, :empty_response_count, :context_warning_emitted
      attr_reader :max_steps, :step_count, :model, :total_tokens, :warn_at_ratio, :runtime_manager, :loop_context, :context_limit, :max_output_tokens, :config
      # Collaborator-facing state (Plan 54 D-5): loop state physically stays on Loop;
      # extracted collaborators reach it through these accessors.
      attr_reader :provider, :on_step, :tool_registry, :shell, :buffer_manager, :lsp_manager, :step_executor,
                  :budget_manager, :stream_manager, :activity

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
        @max_output_tokens = (max_output_tokens || (@config.respond_to?(:fetch) ? @config.fetch("llm.default_max_output_tokens", 4_096) : 4_096)).to_i
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
        # Plan 87 E-1: collaborators reach loop state only through the
        # ShellDeps façade, not through raw @loop reach-through.
        # Review Öneri 3: provider-config resolution follows the same
        # collaborator-extraction pattern (ProviderResolver, built lazily
        # on first use — see #provider_resolver).
        @shell_deps = ShellDeps.new(self)
        @step_executor = StepExecutor.new(@shell_deps)
        @budget_manager = BudgetManager.new(@shell_deps)
        @stream_manager = StreamManager.new(@shell_deps)
        @continuation_manager = ContinuationManager.new(config: @config)
        @subagent_notice_inbox = SubagentNoticeInbox.new
      end

      # §7.2 item 3 (ContinuationManager mold): the notice queue lives in
      # SubagentNoticeInbox; Loop keeps the original public names as
      # delegation shims — repl/lifecycle.rb routes by respond_to?(
      # :enqueue_subagent_notice), so that name is load-bearing.
      def enqueue_subagent_notice(notice) = subagent_notice_inbox.enqueue(notice)

      def drain_subagent_notices_into_history!
        notices = subagent_notice_inbox.drain_all
        return if notices.empty?

        merge_notice_block_into_history!(Rubik::Orchestrator::Subagent::Notices.history_block(notices))
      end

      def merge_notice_block_into_history!(xml_payload)
        if @history.last && (@history.last[:role] == "user" || @history.last["role"] == "user")
          key = @history.last.key?(:content) ? :content : "content"
          existing = @history.last[key].to_s
          @history.last[key] = existing.empty? ? xml_payload : "#{existing}\n\n#{xml_payload}"
        else
          @history << {
            role: "user",
            content: xml_payload
          }
        end
      end

      def subagent_notice_inbox = (@subagent_notice_inbox ||= SubagentNoticeInbox.new)

      def continuation_manager
        @continuation_manager ||= ContinuationManager.new(config: @config)
      end

      def extend_budget(extra_steps) = (@max_steps += extra_steps.to_i)

      def run(task_prompt, model: nil, plan_only: false, goal_mode: false, initial_context: nil, conversation_history: [])
        @step_count = 0
        @history = []
        # Fresh inbox per run, aligned with the history reset; continue_loop
        # deliberately keeps the queue (SubagentNoticeInbox contract docs).
        subagent_notice_inbox.reset_for_new_run!
        @total_tokens = { input: 0, output: 0 }
        @invalid_tool_count = @empty_response_count = 0
        @context_warning_emitted = false
        @activity&.reset!
        continuation_manager&.reset!
        @loop_context = @runtime_manager&.context&.extend

        begin
          target_model = model || @model
          opts = target_model ? { model: target_model } : {}
          opts[:tools] = @tool_registry.schemas unless plan_only

          mode = if plan_only
                   :plan
                 else
                   goal_mode ? :goal : :default
                 end

          system_prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
            mode: mode,
            tool_schemas: plan_only ? [] : @tool_registry.schemas,
            native_tools: !plan_only,
            config: @shell.respond_to?(:config) ? @shell.config : nil,
            commands: @shell.respond_to?(:commands) ? @shell.commands : nil,
            buffer_manager: @buffer_manager,
            snapshot_store: @snapshot_store,
            context_index: @context_index,
            lsp_manager: @lsp_manager,
            context_limit: @context_limit,
            max_output_tokens: @max_output_tokens,
            root_dir: @root_dir,
            extra_context: initial_context,
            skills_index: Rubik::Coeffects.get(@runtime_manager&.context, Rubik::Coeffects::SKILL_MANAGER)&.prompt_index,
            type_registry: resolve_type_registry
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
        # Continuation resumes the same run: pending notices survive into
        # the next execute_steps pass (named no-op on the inbox).
        subagent_notice_inbox.keep_for_continuation
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

      # Shared by both request paths (batch + streaming, Plan 63 Faz A):
      # compact the history in place and emit the :emergency_compact event
      # carrying the layer that produced the final history. Public because
      # StreamManager's compact callable drives it through the ShellDeps
      # façade.
      def emergency_compact_and_notify!(reason)
        layer = Rubik::Prompt::EmergencyCompactor.compact!(
          @history, context_limit: @context_limit, max_output_tokens: @max_output_tokens,
                    config: ProviderRecovery.compaction_config(@config)
        )
        @on_step&.call(type: :emergency_compact, reason: reason, step: @step_count, max_steps: @max_steps, layer: layer)
      end

      def safe_config(key, default)
        return default unless @config.respond_to?(:fetch)

        @config.fetch(key, default) || default
      rescue StandardError
        default
      end

      private

      # Registry-key + llm.* override resolution lives in ProviderResolver
      # (review Öneri 3). Loop keeps thin private delegates with the
      # original names/signatures so call sites and send()-based tests are
      # untouched.
      def provider_registry_key
        provider_resolver.registry_key
      end

      def provider_llm_config(key, default)
        provider_resolver.llm_config(key, default)
      end

      # Built lazily on first use, NOT in initialize: several test doubles
      # construct loops via Class#allocate + instance_variable_set
      # (build_knob_loop), which skips initialize. Reading @provider/
      # @config at first use keeps that pattern working. Memoization is
      # safe: the provider reference is immutable for the loop's lifetime
      # and the config object is held by reference (values re-read per
      # fetch — config reactivity preserved).
      def provider_resolver
        @provider_resolver ||= ProviderResolver.new(provider: @provider, config: @config)
      end

      def resolve_type_registry
        if @runtime_manager&.context.respond_to?(:get)
          sup = Rubik::Coeffects.get(@runtime_manager.context, Rubik::Coeffects::SUBAGENT_SUPERVISOR)
          return sup.type_registry if sup&.type_registry
        end

        Rubik::Orchestrator::Subagent::TypeRegistry.new if @tool_registry&.get("invoke_subagent") && defined?(Rubik::Orchestrator::Subagent::TypeRegistry)
      rescue StandardError
        nil
      end

      def execute_steps(opts:, plan_only: false)
        @invalid_tool_count = 0
        @empty_response_count = 0
        warned = false

        while @step_count < @max_steps
          # Late-notice asymmetry is intentional: notices arriving after the
          # final step drain nowhere — the user channel (turn-end flush) and
          # manage_subagents wait remain their delivery path.
          drain_subagent_notices_into_history!
          @step_count += 1

          warned = evaluate_step_budget_warning!(warned)
          evaluate_context_compaction!

          opts[:tools] = @tool_registry.schemas unless plan_only

          prov_name = provider_registry_key || "custom"

          @on_step&.call(
            type: :thinking,
            step: @step_count,
            max_steps: @max_steps,
            model: opts[:model] || @model,
            provider: prov_name
          )

          res = send_llm_request_with_recovery(opts)
          result = process_step_response(res, opts, plan_only: plan_only)
          return result if result
        end

        { ok: false, error: "Max steps budget exceeded (#{@max_steps})", steps: @step_count, tokens: @total_tokens, loop_instance: self }
      end

      def evaluate_step_budget_warning!(warned) = @budget_manager.evaluate_step_budget_warning!(warned)
      def evaluate_context_compaction! = @budget_manager.evaluate_context_compaction!

      def send_llm_request_with_recovery(opts)
        streaming_enabled = if opts.key?(:stream)
                              opts[:stream] == true
                            else
                              provider_llm_config("stream", true) != false
                            end

        # Plan 61 D-1/D-3: the wire request must share the compaction math's
        # assumptions. Ollama needs context_limit (sent as num_ctx) or its
        # server silently clips the prompt head to the model default; strict
        # providers need max_tokens or output falls back to tiny defaults
        # (e.g. Anthropic's 1024).
        effective_opts = opts.key?(:on_retry) ? opts.dup : opts.merge(on_retry: @stream_manager.llm_retry_notifier)
        effective_opts[:context_limit] = @context_limit if @context_limit
        effective_opts[:max_tokens] = @max_output_tokens if @max_output_tokens&.positive?
        effective_opts[:stream_timeout] ||= provider_llm_config("stream_timeout", ProviderRecovery::STREAM_REQUEST_TIMEOUT)
        effective_opts[:open_timeout] ||= provider_llm_config("open_timeout", ProviderRecovery::DEFAULT_OPEN_TIMEOUT)
        effective_opts[:timeout] ||= effective_opts[:stream_timeout]

        if streaming_enabled && @provider.respond_to?(:stream_chat)
          @stream_manager.execute_streaming_request(effective_opts)
        else
          execute_batch_request(effective_opts)
        end
      end

      def execute_batch_request(opts)
        @last_turn_streamed = false
        ProviderRecovery.with_recovery(config: @config, compact: method(:emergency_compact_and_notify!)) do
          @provider.complete(@history, opts)
        end
      end

      def track_token_usage!(res) = @budget_manager.track_token_usage!(res)

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

      def extract_finish_reason(res)
        return nil unless res.respond_to?(:raw) && res.raw.is_a?(Hash)

        raw = res.raw
        raw["finish_reason"] || raw.dig("choices", 0, "finish_reason") || raw["stop_reason"] || raw.dig("delta", "stop_reason") || raw["done_reason"]
      end

      def process_step_response(res, _opts = {}, plan_only: false)
        track_token_usage!(res)

        text_resp = res.text.to_s.strip

        tool_calls = extract_and_normalize_tool_calls(res, text_resp)
        finish_reason = extract_finish_reason(res).to_s
        max_tokens = @max_output_tokens || safe_config("llm.default_max_output_tokens", 4096)

        # Plan 90: Token budget autonomy — handle truncation before failing or prematurely accepting
        if continuation_manager.truncation?(finish_reason)
          trunc_action = continuation_manager.handle_truncation(
            finish_reason: finish_reason,
            text_resp: res.text.to_s,
            tool_calls: tool_calls,
            res: res,
            max_tokens: max_tokens
          )

          if trunc_action[:continue]
            @empty_response_count = 0
            if trunc_action[:thought]
              @history << { role: "assistant", content: nil, thought: trunc_action[:thought] }
            elsif trunc_action[:partial_text]
              @history << { role: "assistant", content: trunc_action[:partial_text] }
            end
            @history << { role: "user", content: trunc_action[:nudge] }
            @on_step&.call(trunc_action[:step_event].merge(step: @step_count, max_steps: @max_steps)) if trunc_action[:step_event]
            return nil
          elsif trunc_action[:error]
            @on_step&.call(type: :error, content: trunc_action[:error], step: @step_count, max_steps: @max_steps)
            return { ok: false, error: trunc_action[:error] }
          end
        end

        # Plan mode is text-only — enforced in code, not just by prompt:
        # native tools are withheld from the request AND tool-call parsing/
        # execution is disabled here, so a model cannot mutate the workspace
        # by emitting a JSON tool block.
        if plan_only
          if text_resp.empty?
            @empty_response_count += 1
            return turn_result(success: false, error: "Empty response from model") if @empty_response_count >= 2

            @history << { role: "user", content: "Plan mode: tool calls are disabled. Respond with the numbered implementation plan as plain text." }
            return nil
          end

          @empty_response_count = 0
          final_text = stitch_response(res, text_resp)
          @history << { role: "assistant", content: final_text }
          @on_step&.call(type: :message, content: final_text, step: @step_count, max_steps: @max_steps)
          return turn_result(success: true, output: final_text)
        end

        if tool_calls.empty?
          # Plan 61 D-11: an empty reply used to end the turn silently with
          # output:"" — one nudge keeps the loop going; two in a row bail out.
          if text_resp.empty?
            @empty_response_count += 1
            return turn_result(success: false, error: "Empty response from model") if @empty_response_count >= 2

            nudge_msg = if res.respond_to?(:thought) && res.thought && !res.thought.to_s.strip.empty?
                          "Your reasoning was completed, but no action or final response was provided. Please call a tool or provide your final output."
                        else
                          "Your last response was empty. Continue the task or call the finish tool."
                        end
            @history << { role: "user", content: nudge_msg }
            return nil
          end

          @empty_response_count = 0
          final_text = stitch_response(res, text_resp)
          @history << { role: "assistant", content: final_text }
          @on_step&.call(type: :message, content: final_text, step: @step_count, max_steps: @max_steps)
          return turn_result(success: true, output: final_text)
        end

        # Record assistant message with tool_calls in history
        @empty_response_count = 0
        final_text = stitch_response(res, text_resp)
        @history << { role: "assistant", content: final_text.empty? ? nil : final_text, tool_calls: tool_calls }

        @on_step&.call(type: :llm_thought, content: text_resp, step: @step_count, max_steps: @max_steps) if !text_resp.empty? && tool_calls.none? { |tc| finish_call?(tc) }

        execute_tool_calls(tool_calls, text_resp)
      end

      def execute_tool_calls(tool_calls, text_resp)
        tool_calls.each do |tc|
          res = execute_single_tool_call(tc, text_resp)
          return res if res
        end
        nil
      end

      def execute_single_tool_call(...) = @step_executor.execute_single_tool_call(...)
      def handle_finish_tool(...) = @step_executor.handle_finish_tool(...)
      def execute_registered_tool(...) = @step_executor.execute_registered_tool(...)
      def handle_invalid_tool(...) = @step_executor.handle_invalid_tool(...)

      def finish_call?(tool_call)
        t_name = tool_call["tool"] || tool_call[:tool]
        resolved = @tool_registry.get(t_name)
        (resolved ? resolved.name : t_name.to_s.downcase) == "finish"
      end

      def parse_tool_call(text)
        cleaned = text.to_s.gsub("\\n", "\n")
        json_str = if cleaned.include?("```json")
                     cleaned.split("```json").last.split("```").first.strip
                   elsif cleaned.start_with?("{") && cleaned.end_with?("}")
                     cleaned
                   end
        json_str ? JSON.parse(json_str) : nil
      rescue StandardError
        nil
      end

      def stitch_response(res, text_resp)
        if continuation_manager.continuation_buffer.empty?
          text_resp
        else
          continuation_manager.stitch_and_reset(res.text.to_s)
        end
      end

      def turn_result(success:, error: nil, output: nil)
        r = { ok: success, steps: @step_count, tokens: @total_tokens, streamed: @last_turn_streamed == true, loop_instance: self }
        r[:output] = output if output
        r[:error] = error if error
        r
      end
    end
  end
end
