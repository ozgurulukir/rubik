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
require_relative "goal_wait"
require_relative "subagent_notice_inbox"
require_relative "turn_executor"
require_relative "turn_executor/user_channel"
require_relative "tool_call_id"
require_relative "subagent/notices"

module Rubik
  module Orchestrator
    class Loop
      attr_accessor :history, :invalid_tool_count, :last_turn_streamed, :context_warning_emitted
      attr_reader :max_steps, :step_count, :model, :total_tokens, :warn_at_ratio, :runtime_manager, :loop_context, :context_limit, :max_output_tokens, :config
      # Collaborator-facing state (Plan 54 D-5): loop state physically stays on Loop;
      # extracted collaborators reach it through these accessors.
      attr_reader :provider, :on_step, :tool_registry, :shell, :buffer_manager, :lsp_manager, :step_executor,
                  :budget_manager, :stream_manager, :activity

      # Channel-owned counter (TurnExecutor::NudgePolicy); the public reader
      # name is load-bearing (tests, REPL surfaces).
      def empty_response_count = turn_executor.nudge_policy.count

      def initialize(provider:, tool_registry:, max_steps: 40, warn_at_ratio: 0.75, model: nil, on_step: nil, shell: nil, context_limit: nil,
                     max_output_tokens: nil)
        @provider = provider
        @tool_registry = tool_registry
        @max_steps = (max_steps || 40).to_i
        @warn_at_ratio = (warn_at_ratio || 0.75).to_f
        @model = model
        @on_step = on_step
        # The shell must be STABLE from construction through run(): the
        # ivars below snapshot its services at initialize (execution uses
        # these), while the system prompt re-reads the public readers at
        # run() start (Prompt::Services.from_shell) — a service swapped
        # in between would make prompt and execution disagree.
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
        @goal_mode = false
        @goal_wait = nil
      end

      # §7.2 item 3 (ContinuationManager mold): the notice queue lives in
      # SubagentNoticeInbox; Loop keeps the original public names as
      # delegation shims — repl/lifecycle.rb routes by respond_to?(
      # :enqueue_subagent_notice), so that name is load-bearing.
      def enqueue_subagent_notice(notice) = subagent_notice_inbox.enqueue(notice)

      def drain_subagent_notices_into_history!
        notices = subagent_notice_inbox.drain_all
        return notices if notices.empty?

        merge_notice_block_into_history!(Rubik::Orchestrator::Subagent::Notices.history_block(notices))
        notices
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

      # Goal-mode flag (run/continue_loop lifecycle above) and the
      # premature-completion guard collaborator. Lazy so Class#allocate
      # test doubles — which skip initialize — answer goal_mode? false and
      # never build the collaborator off a nil @shell_deps.
      def goal_mode? = @goal_mode == true

      def goal_wait
        @goal_wait ||= GoalWait.new(@shell_deps)
      end

      def continuation_manager
        @continuation_manager ||= ContinuationManager.new(config: @config)
      end

      # Agent-turn-executor plan: response processing is shared with the
      # subagent channel through TurnExecutor; Loop supplies the
      # user-channel adapter. Built lazily on first use, NOT in
      # initialize: several test doubles construct loops via
      # Class#allocate + instance_variable_set (build_knob_loop), which
      # skips initialize.
      def turn_executor
        @turn_executor ||= TurnExecutor.new(channel: TurnExecutor::UserChannel.new(self))
      end

      def extend_budget(extra_steps) = (@max_steps += extra_steps.to_i)

      def run(task_prompt, model: nil, plan_only: false, goal_mode: false, initial_context: nil, conversation_history: [])
        @step_count = 0
        @history = []
        # Goal-mode marker for the premature-completion guard (GoalWait):
        # set per run so a reused Loop instance cannot inherit the flag;
        # continue_loop deliberately keeps it (same run resumed).
        @goal_mode = goal_mode
        # Fresh inbox per run, aligned with the history reset; continue_loop
        # deliberately keeps the queue (SubagentNoticeInbox contract docs).
        subagent_notice_inbox.reset_for_new_run!
        @total_tokens = { input: 0, output: 0 }
        @invalid_tool_count = 0
        turn_executor.reset!
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

          # Prompt view built once at the composition boundary: the
          # orchestrator resolves coeffects (skills index, type registry)
          # and the prompt layer only renders (candidate 2, Phase 2).
          services = Rubik::Prompt::Services.from_shell(@shell,
                                                        skills_index: Rubik::Coeffects.get(@runtime_manager&.context, Rubik::Coeffects::SKILL_MANAGER)&.prompt_index,
                                                        type_registry: resolve_type_registry,
                                                        context_limit: @context_limit,
                                                        max_output_tokens: @max_output_tokens,
                                                        root_dir: @root_dir,
                                                        extra_context: initial_context)
          system_prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
            mode: mode,
            tool_schemas: plan_only ? [] : @tool_registry.schemas,
            native_tools: !plan_only,
            services: services
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
        # Retention seam — see SubagentNoticeInbox#keep_for_continuation.
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
      # façade. The compaction body lives in TurnExecutor#emergency_compact!
      # — one home for both channels; the announce is channel-parameterized.
      def emergency_compact_and_notify!(reason)
        turn_executor.emergency_compact!(reason)
      end

      def safe_config(key, default)
        return default unless @config.respond_to?(:fetch)

        @config.fetch(key, default) || default
      rescue KeyError, TypeError, NoMethodError
        default
      end

      # Turn-result contract (public: the TurnExecutor user-channel adapter
      # builds every terminal through it, and the shell drives
      # continue_loop off the carried loop_instance).
      def turn_result(success:, error: nil, output: nil)
        r = { ok: success, steps: @step_count, tokens: @total_tokens, streamed: @last_turn_streamed == true, loop_instance: self }
        r[:output] = output if output
        r[:error] = error if error
        r
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
      rescue StandardError => e
        Rubik::Platform.debug_warn("type registry resolution failed (#{e.class}: #{e.message}); subagent typing degraded")
        nil
      end

      def execute_steps(opts:, plan_only: false)
        @invalid_tool_count = 0
        turn_executor.reset!
        warned = false

        while @step_count < @max_steps
          # Late-notice asymmetry is intentional: notices arriving after the
          # final step drain nowhere — the user channel (turn-end flush) and
          # manage_subagents wait remain their delivery path.
          drain_subagent_notices_into_history!
          @step_count += 1

          warned = @budget_manager.evaluate_step_budget_warning!(warned)
          @budget_manager.evaluate_context_compaction!

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
          result = turn_executor.call(res, plan_only: plan_only)
          return result if result
        end

        { ok: false, error: "Max steps budget exceeded (#{@max_steps})", steps: @step_count, tokens: @total_tokens, loop_instance: self }
      end

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
        # Plan 90 completion: the llm.thinking_budget_ratio / llm.reasoning_effort
        # knobs reach the adapters only through this bridge. Both default to nil
        # (never sent); the key must stay ABSENT when unset — openai_compatible's
        # reasoning_model? tests opts.key?(:reasoning_effort), so even a nil
        # value would flip every model onto the reasoning payload branch.
        ratio = provider_llm_config("thinking_budget_ratio", nil)
        effective_opts[:thinking_budget_ratio] ||= ratio if ratio
        effort = provider_llm_config("reasoning_effort", nil)
        effective_opts[:reasoning_effort] ||= effort if effort

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
    end
  end
end
