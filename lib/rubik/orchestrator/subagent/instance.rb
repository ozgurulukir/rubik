# frozen_string_literal: true

require "monitor"
require "json"
require "fileutils"
require_relative "transcript_formatter"
require_relative "step_runner"
require_relative "budget"
require_relative "notices"
require_relative "resilience"
require_relative "../../prompt"
require_relative "../../tools/truncator"

module Rubik
  module Orchestrator
    module Subagent
      # Autonomous background subagent execution instance running in an isolated
      # disposable sub-context with its own message inbox, tool slice, and lifecycle (Plan 94, Plan 95).
      class Instance
        include StepRunner

        attr_accessor :parent_id
        attr_reader :id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :context, :tool_registry, :buffer_manager,
                    :state, :started_at, :ended_at, :result,
                    :last_error, :transcript_uri, :transcript_path, :history,
                    :context_limit, :max_output_tokens, :config

        # Budget delegation: the step counters live in Subagent::Budget; these
        # preserve the pre-extraction reader contract (tools, REPL, transcript
        # formatter).
        def current_step = @budget.current_step
        def max_steps = @budget.max_steps

        def initialize(id:, parent_id:, role:, type_name:, prompt:, context:, tool_registry:,
                       system_prompt: nil, workspace: "inherit", model: "inherit",
                       provider: nil, buffer_manager: nil, max_steps: Budget::DEFAULT_MAX_STEPS, root_dir: Dir.pwd,
                       context_limit: nil, config: nil, event_bus: nil, provider_gate: nil)
          @id = id.to_s
          @parent_id = parent_id.to_s
          @role = role.to_s.strip
          @type_name = type_name.to_s.downcase.strip
          @prompt = prompt.to_s.strip
          @system_prompt = system_prompt
          @workspace = workspace.to_s.downcase.strip
          @model = model
          @context = context
          @tool_registry = tool_registry
          @provider = provider
          @buffer_manager = buffer_manager
          @budget = Budget.new(max_steps: max_steps)
          @root_dir = root_dir
          @config = config
          @event_bus = event_bus
          @provider_gate = provider_gate
          @context_limit = (context_limit || (@config.respond_to?(:fetch) ? @config.fetch("context.max_tokens", 32_768) : 32_768) || 32_768).to_i
          @max_output_tokens = (@config.respond_to?(:fetch) ? @config.fetch("llm.default_max_output_tokens", 4_096) : 4_096).to_i

          @state = :pending
          @history = []
          @inbox = Queue.new
          @started_at = @ended_at = @result = @last_error = @transcript_path = nil
          @transcript_uri = File.join(".rubik", "subagents", @id, "transcript.jsonl")
          @monitor = Monitor.new
          @budget_cond = @monitor.new_cond
          @error_cond = @monitor.new_cond
          @context_cleaned_up = false
          @thread = nil
        end

        def running?
          @state == :running || @state == :waiting_input || @state == :waiting_budget || @state == :paused_error
        end

        def active?
          [:pending, :running, :waiting_input, :waiting_budget, :paused_error, :canceling].include?(@state)
        end

        def uptime
          return 0.0 unless @started_at

          ((@ended_at || Time.now) - @started_at).to_f
        end

        def post_message(message, additional_steps: nil)
          @monitor.synchronize do
            @inbox.push(message)
            if @state == :paused_error
              resume!(additional_steps: additional_steps)
            elsif @state == :waiting_budget || additional_steps
              grant_budget!(additional_steps, note: lambda { |extra, total|
                Budget.message_grant_note(extra, total)
              })
            end
          end
        end

        def resume!(additional_steps: nil)
          @monitor.synchronize do
            return false if [:completed, :disposed, :canceling].include?(@state)

            if @state == :paused_error
              @state = :running
              @last_error = nil
              @budget.grant!(additional_steps) if additional_steps&.to_i&.positive?
              @error_cond.broadcast
              true
            elsif @state == :waiting_budget
              grant_budget!(additional_steps || Budget::DEFAULT_GRANT_STEPS,
                            note: ->(extra, total) { Budget.grant_note(extra, total) })
            else
              false
            end
          end
        end

        def extend_budget(additional_steps = Budget::DEFAULT_GRANT_STEPS)
          grant_budget!(additional_steps, note: lambda { |extra, total|
            Budget.grant_note(extra, total)
          })
        end

        def start_async(&on_complete)
          @monitor.synchronize do
            return false if @thread&.alive?

            @started_at = Time.now
            @state = :running
          end

          @thread = Thread.new do
            run_execution_cycle
          ensure
            @ended_at ||= Time.now
            save_transcript! if @transcript_path.nil?
            cleanup_context
            on_complete&.call(self)
          end
          true
        end

        def kill
          @monitor.synchronize do
            return true if @state == :disposed

            @state = :canceling
            @ended_at = Time.now
            @budget_cond.broadcast
            @error_cond.broadcast
          end

          begin
            @thread&.kill if @thread&.alive?
          rescue StandardError
            nil
          end

          cleanup
          true
        end

        def cleanup
          @monitor.synchronize do
            return if @state == :disposed

            @budget_cond.broadcast
            @error_cond.broadcast
            cleanup_context
            @state = :disposed
          end
        end

        # Idempotent under monitor: check-and-set of @context_cleaned_up prevents
        # races between the worker's ensure block and kill's cleanup path.
        def cleanup_context
          @monitor.synchronize do
            return if @context_cleaned_up

            @context_cleaned_up = true
            begin
              @context&.dispose unless @context&.disposed?
            rescue StandardError => e
              @last_error ||= "#{e.class}: #{e.message}"
            end
          end
        end

        def to_h
          @monitor.synchronize do
            { id: @id, parent_id: @parent_id, role: @role, type: @type_name, state: @state.to_s,
              **@budget.to_h, uptime_seconds: uptime.round(2),
              started_at: @started_at&.iso8601, ended_at: @ended_at&.iso8601,
              transcript: @transcript_path || @transcript_uri, last_error: @last_error,
              result_summary: @result&.to_s&.slice(0, 100), result: @result }
          end
        end

        def format_transcript
          TranscriptFormatter.format(self, @history, @monitor)
        end

        private

        # Private by design: a grant must pair with the terminal guard, the
        # history note, and the broadcast — all lifecycle facts owned here.
        # Tests drive budget states through supervisor + provider, never by
        # reaching into this reader.
        attr_reader :budget

        def save_transcript!
          saved = TranscriptFormatter.save!(@root_dir, @id, @history, @monitor)
          return unless saved

          @transcript_path = @transcript_uri = saved
        end

        def run_execution_cycle
          effective_sys_prompt = build_effective_system_prompt
          @history << { role: "system", content: effective_sys_prompt }
          @history << { role: "user", content: @prompt }

          unless @provider
            @budget.consume
            @result = "Subagent [#{@id}] (#{@role}) completed task successfully: #{@prompt.slice(0, 80)}"
            @state = :completed
            save_transcript!
            return
          end

          execute_steps_with_provider
          save_transcript!
        rescue StandardError => e
          @monitor.synchronize do
            @last_error = "#{e.class}: #{e.message}"
            @state = :failed
          end
          save_transcript!
        end

        # The single budget-grant core (Candidate 03): terminal guard ->
        # grant -> resume -> note -> broadcast. Note wording lives in
        # Budget.grant_note/message_grant_note (audience boundary: the
        # subagent's own loop); call sites pass a lambda receiving extra +
        # new total. The budget mechanics (normalize -> floor -> += -> warn
        # re-arm) run inside @budget.grant! under the Budget lock
        # (lock order: instance -> budget).
        # Monitor-reentrant (both wrappers synchronize); the broadcast is a
        # harmless no-op when nobody waits. Terminal and canceling states
        # refuse the grant — a dying or dead instance must not resurrect
        # (kill's race window included).
        def grant_budget!(steps, note:)
          @monitor.synchronize do
            return false if [:completed, :failed, :disposed, :canceling, :budget_exhausted].include?(@state)

            extra, total = @budget.grant!(steps)
            @state = :running
            @history << { role: "user", content: note.call(extra, total) }
            @budget_cond.broadcast
            @error_cond.broadcast
            true
          end
        end

        def pause_and_await_budget_expansion!(wait_timeout = nil)
          payload = nil
          @monitor.synchronize do
            return false unless @state == :running

            @state = :waiting_budget
            @result = "Paused awaiting budget expansion from init-0."
            payload = { id: @id, role: @role, state: @state, max_steps: @budget.max_steps }
          end

          # The object that owns the fact emits it (outside the monitor, so
          # subscribers never run under the instance lock).
          @event_bus&.emit(Notices::BUDGET_EXHAUSTED_EVENT, payload)

          timeout = wait_timeout || (@config.respond_to?(:fetch) ? @config.fetch("subagents.budget_wait_timeout", 180) : 180) || 180
          @monitor.synchronize do
            @budget_cond.wait(timeout) if @state == :waiting_budget
            if @state == :waiting_budget
              @state = :budget_exhausted
              @result = "#{Notices.budget_exhausted_line(@budget.max_steps)} Budget expansion was not received from init-0."
              false
            else
              @state = :running
            end
          end
        end

        def pause_on_error!(error, wait_timeout = nil)
          payload = nil
          @monitor.synchronize do
            return false unless @state == :running

            @state = :paused_error
            @last_error = "#{error.class}: #{error.message}"
            @result = "Paused awaiting error recovery: #{@last_error}"
            payload = { id: @id, role: @role, state: @state, error: @last_error }
          end

          @event_bus&.emit(Notices::ERROR_PAUSED_EVENT, payload)

          timeout = wait_timeout ||
                    (@config.respond_to?(:fetch) && @config.fetch("subagents.error_wait_timeout", nil)) ||
                    Resilience::DEFAULT_ERROR_WAIT_TIMEOUT
          @monitor.synchronize do
            @error_cond.wait(timeout) if @state == :paused_error
            if @state == :paused_error
              @state = :failed
              @result = "Subagent halted after #{timeout}s in paused_error state: #{@last_error}"
              false
            else
              @state = :running
              true
            end
          end
        end

        def build_effective_system_prompt
          base = "You are a specialized subagent operating under autonomous supervision.\n\n" \
                 "Subagent ID: #{@id} | Role: #{@role} | Type: #{@type_name}\n\n" \
                 "Perform your assigned task with high precision and provide a structured synthesis report."
          @system_prompt && !@system_prompt.strip.empty? ? "#{base}\n\nCustom Instructions:\n#{@system_prompt}" : base
        end
      end
    end
  end
end
