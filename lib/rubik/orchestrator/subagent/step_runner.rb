# frozen_string_literal: true

require "json"
require_relative "../../prompt"
require_relative "../../tools/truncator"
require_relative "../provider_recovery"
require_relative "../auto_apply"
require_relative "../tool_call_id"
require_relative "../tool_history"
require_relative "../turn_executor"
require_relative "../turn_executor/subagent_channel"
require_relative "../../coeffects"
require_relative "notices"
require_relative "resilience"

module Rubik
  module Orchestrator
    module Subagent
      # Step execution loop, compaction evaluation, emergency recovery, and tool dispatch
      # extracted from Instance to satisfy module hygiene and maintain vertical cohesion (Plan 95);
      # budget state is reached only through the shared Budget collaborator (Candidate 04).
      # Response processing itself is shared with the user channel through the TurnExecutor
      # spine (agent-turn-executor plan); this module keeps the invocation path, budget
      # mechanics, and the subagent dispatch.
      module StepRunner
        # The shared response-processing spine, built lazily on first use so
        # objects that skip initialize (test doubles) stay safe.
        def turn_executor
          @turn_executor ||= Rubik::Orchestrator::TurnExecutor.new(
            channel: Rubik::Orchestrator::TurnExecutor::SubagentChannel.new(self)
          )
        end

        def execute_steps_with_provider
          turn_executor.reset!
          loop do
            while !@budget.exhausted? && executing?
              @budget.consume
              drain_inbox_into_history
              inject_step_marker
              evaluate_subagent_context_compaction!

              opts = { tools: (@tool_registry.respond_to?(:schemas) ? @tool_registry.schemas : []) }
              opts[:model] = @model unless @model.nil? || @model == "inherit"

              begin
                raw_response = invoke_provider_with_recovery(opts)
              rescue StandardError => e
                if Resilience.transient_error?(e) && auto_pause_on_error?
                  break unless pause_on_error!(e)

                  next
                end
                raise e
              end

              terminal = turn_executor.call(raw_response)
              return if terminal
            end

            break unless executing? && @budget.exhausted?
            break unless pause_and_await_budget_expansion!
          end
        end

        # Public seams for the SubagentChannel adapter (a separate object —
        # it cannot reach this module's context). Recording the outcome and
        # transitioning stay paired here so the lifecycle's only-mutation-
        # path doctrine holds.
        def complete_turn!(result)
          @result = result
          transition!(:completed)
        end

        def fail_turn!(reason)
          @last_error = reason
          transition!(:failed)
        end

        def evaluate_subagent_context_compaction!
          return unless @context_limit&.positive?

          context_cfg = ProviderRecovery.compaction_config(@config)
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
          ProviderRecovery.with_recovery(config: @config, compact: method(:emergency_compact_and_notify!)) do
            Resilience.retry_transient(config: @config, gate: @provider_gate) do
              invoke_provider(opts)
            end
          end
        end

        def auto_pause_on_error?
          @config.respond_to?(:fetch) ? @config.fetch("subagents.auto_pause_on_network_error", true) != false : true
        end

        # Compaction actuator for the subagent path (mirrors Loop's public
        # seam of the same name): the compaction body lives in
        # TurnExecutor#emergency_compact! (one home for both channels); this
        # delegates and the channel announces on the bus. Runs on the worker
        # thread between monitor sections — never call it while holding
        # @monitor (the emit stays lock-free).
        def emergency_compact_and_notify!(reason)
          turn_executor.emergency_compact!(reason)
        end

        # The object that owns the fact emits it — outside the monitor, so
        # subscribers never run under the instance lock.
        def emit_compacted_event(reason, layer)
          Notices.emit(@event_bus, Notices::COMPACTED_EVENT, { id: @id, role: @role, state: @state, reason: reason.to_s, layer: layer })
        end

        def invoke_provider(opts)
          effective_opts = opts.dup
          effective_opts[:timeout] ||= ProviderRecovery::SUBAGENT_REQUEST_TIMEOUT
          effective_opts[:open_timeout] ||= ProviderRecovery::DEFAULT_OPEN_TIMEOUT
          effective_opts[:context_limit] ||= @context_limit if @context_limit
          effective_opts[:max_tokens] ||= @max_output_tokens if @max_output_tokens&.positive?

          return @provider.complete(@history, effective_opts) if @provider.respond_to?(:complete)
          return @provider.chat(@history, **effective_opts) if @provider.respond_to?(:chat)

          raise "Provider #{@provider.class} does not support complete or chat"
        end

        def drain_inbox_into_history
          until @inbox.empty?
            begin
              entry = @inbox.pop(true)
              @history << { role: "user", content: "[Message from #{sender_label(entry)}]: #{entry.text}" } if entry
            rescue ThreadError
              break
            end
          end
        end

        # İki-düzlem sözleşme: gönderen yoksa ya da makine adı agent-0'sa
        # model persona'sı maestro ile etiketlenir; subagent gönderenler
        # (sibling mesajları) kendi id'leriyle görünür.
        def sender_label(entry)
          return "maestro" if entry.from.nil? || entry.from == "agent-0"

          entry.from
        end

        # Single-call subagent dispatch (the TurnExecutor's per-call seam):
        # pre-execution auto-apply, timed execution, and the canonical
        # ToolHistory row — which now carries status + duration_ms like every
        # other channel (the row-superset delta of the agent-turn-executor
        # plan; no wire-side formatter reads them, observability only).
        def execute_subagent_tool_call(tool_call)
          name = tool_call["tool"]
          args = tool_call["args"] || {}
          tool = @tool_registry.respond_to?(:get) ? @tool_registry.get(name) : nil
          canonical_name = tool ? tool.name : name.to_s.downcase

          auto_apply_buffer!(:pre_execution, tool: canonical_name)

          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          output, status = dispatch_subagent_tool(tool, name, args)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          Rubik::Orchestrator::ToolHistory.write(@history, tool_call_id: tool_call["id"], tool_name: name,
                                                           status: status, duration_ms: duration_ms, content: output.to_s)
          nil
        end

        # The subagent's own spelling of the shared auto-apply policy (AutoApply
        # owns the decision): decide, apply+sync through the coeffect shell,
        # and REPORT failures instead of swallowing them — a failed pre-test
        # apply used to mean tests silently ran on stale disk. The decision
        # sits OUTSIDE the rescue: a policy bug must fail the subagent as a
        # code error, not masquerade as a runtime apply failure. Runs on the
        # worker thread between monitor sections — never call it while
        # holding @monitor (same discipline as emergency_compact_and_notify!).
        def auto_apply_buffer!(trigger, tool: nil)
          return unless AutoApply.apply?(@config, trigger: trigger, subagent: true, tool: tool)

          begin
            AutoApply.apply_and_sync(@buffer_manager, coeffect_shell)
            AutoApply.report_conflicts(@event_bus, @buffer_manager,
                                       id: @id, role: @role, state: @state, trigger: trigger)
          rescue StandardError => e
            AutoApply.report_failure(@event_bus, id: @id, role: @role, state: @state,
                                                 trigger: trigger, reason: "#{e.class}: #{e.message}")
            # The subagent itself is the actor about to trust the disk (its
            # next step is usually run_tests) — a parent notice alone keeps
            # the one participant who could react in the dark.
            @history << { role: "user",
                          content: "[AutoApply] buffer auto-apply (#{trigger}) failed: #{e.message}" }
          end
        end

        # The subagent's own child context walks the parent chain to the
        # root-provided :shell, so its applies sync the AST index exactly
        # like every main-path apply (previously this path never synced).
        def coeffect_shell
          Rubik::Coeffects.get(@context, Rubik::Coeffects::SHELL)
        end

        # Returns [truncated_output, status] so the dispatch site can build
        # the canonical tool row. Unknown tools and execution errors carry
        # :error; plain results are :ok (Result-backed tools carry their own).
        def dispatch_subagent_tool(tool, name, args)
          return ["Tool '#{name}' is not available in subagent toolset.", :error] unless tool

          raw = tool.execute(args)
          out_str = raw.respond_to?(:output) ? raw.output.to_s : raw.to_s
          max_chars = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_chars", 12_000) : 12_000) || 12_000
          max_lines = (@config.respond_to?(:fetch) ? @config.fetch("tools.max_output_lines", 300) : 300) || 300
          trunc = Rubik::Tools::Truncator.truncate(out_str, max_chars: max_chars.to_i, max_lines: max_lines.to_i)
          status = raw.respond_to?(:status) ? raw.status : :ok
          [trunc[:text], status]
        rescue StandardError => e
          ["Tool execution error: #{e.class}: #{e.message}", :error]
        end

        private

        # Plan 109 Faz A: per-step budget transparency replaces the 75%
        # warning latch — Budget owns the marker string under its lock; the
        # step loop owns only the history mutation (a conversation fact),
        # the same split the warning used.
        def inject_step_marker
          @history << { role: "user", content: @budget.step_marker }
        end
      end
    end
  end
end
