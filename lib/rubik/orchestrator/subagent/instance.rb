# frozen_string_literal: true

require "monitor"
require "json"
require "fileutils"
require_relative "transcript_formatter"
require_relative "storage_id"
require_relative "lifecycle"
require_relative "step_runner"
require_relative "budget"
require_relative "questioner"
require_relative "reuse"
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
        # Lifecycle (first include) owns the state vocabulary: TRANSITIONS,
        # transition!, and every predicate.
        include Lifecycle
        include StepRunner
        include Questioner
        include Redeploy
        include Reaper

        attr_accessor :parent_id, :unit
        # `state`: the sanctioned raw reader — display/serialization/kernel
        # bridge only; control flow asks the Lifecycle predicates.
        attr_reader :id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :context, :tool_registry, :buffer_manager,
                    :state, :started_at, :ended_at, :result,
                    :last_error, :storage_id, :transcript_uri, :history,
                    :context_limit, :max_output_tokens, :config

        # Budget delegation: step counters live in Subagent::Budget (reader contract preserved).
        def current_step = @budget.current_step
        def max_steps = @budget.max_steps

        def initialize(id:, parent_id:, role:, type_name:, prompt:, context:, tool_registry:,
                       system_prompt: nil, workspace: "inherit", model: "inherit",
                       provider: nil, buffer_manager: nil, max_steps: Budget::DEFAULT_MAX_STEPS, root_dir: Dir.pwd,
                       context_limit: nil, config: nil, event_bus: nil, provider_gate: nil, transcript_storage: nil)
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
          # SSOT (Plan 110): minted once; absorb (transcript_storage) kökü değiştirir.
          @storage_id = StorageId.mint(@id)
          @transcript_uri = TranscriptFormatter.mint_path(@root_dir, @storage_id, storage: transcript_storage)
          @monitor = Monitor.new
          @budget_cond = @monitor.new_cond
          @error_cond = @monitor.new_cond
          @context_cleaned_up = false
          @thread = nil
        end

        def uptime = @started_at ? ((@ended_at || Time.now) - @started_at).to_f : 0.0

        # Inbox girdisi: mesaj metni + GERÇEK gönderen id'si. nil veya makine
        # adı "agent-0" gönderenler render'da maestro persona'sına çevrilir
        # (iki-düzlem adlandırma sözleşmesi) — subagent gönderenler kendi
        # id'leriyle görünür (drain: StepRunner#sender_label).
        InboxMessage = Struct.new(:text, :from)

        def post_message(message, sender: nil, additional_steps: nil)
          @monitor.synchronize do
            @inbox.push(InboxMessage.new(message, sender))
            if error_paused?
              resume!(additional_steps: additional_steps)
            elsif awaiting_budget? || additional_steps
              grant_budget!(additional_steps, note: ->(extra, total) { Budget.message_grant_note(extra, total) })
            end
          end
        end

        def resume!(additional_steps: nil)
          @monitor.synchronize do
            return false if terminal?

            if error_paused?
              transition!(:running)
              @last_error = nil
              @budget.grant!(additional_steps) if additional_steps&.to_i&.positive?
              @error_cond.broadcast
              @unit&.sync_state!
              true
            elsif awaiting_budget?
              grant_budget!(additional_steps || Budget::DEFAULT_GRANT_STEPS,
                            note: ->(extra, total) { Budget.grant_note(extra, total) })
            else
              false
            end
          end
        end

        def extend_budget(additional_steps = Budget::DEFAULT_GRANT_STEPS)
          grant_budget!(additional_steps, note: ->(extra, total) { Budget.grant_note(extra, total) })
        end

        def start_async(&on_complete)
          @monitor.synchronize do
            return false if @thread&.alive?

            @started_at = Time.now
            transition!(:running)
            @unit&.sync_state!
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
            return true if disposed?

            transition!(:canceling)
            @ended_at = Time.now
            @budget_cond.broadcast
            @error_cond.broadcast
          end

          begin; @thread&.kill if @thread&.alive?; rescue StandardError; nil; end

          cleanup
          true
        end

        def cleanup
          @monitor.synchronize do
            return if disposed?

            @budget_cond.broadcast
            @error_cond.broadcast
            cleanup_context
            transition!(:disposed)
          end
        end

        # Idempotent under monitor: check-and-set of @context_cleaned_up (ensure block vs kill cleanup race).
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
              transcript: @transcript_uri, last_error: @last_error,
              result_summary: @result&.to_s&.slice(0, 100), result: @result }
          end
        end

        def format_transcript
          TranscriptFormatter.format(self, @history, @monitor)
        end

        private

        # The run's single failure drain: record why, land on :failed, sync
        # the unit, persist — the loud prefix keeps an FSM violation
        # distinguishable from a provider failure.
        def fail_run(reason)
          @monitor.synchronize do
            @last_error = reason
            transition!(:failed)
            @unit&.sync_state!
          end
          save_transcript!
        end

        # Private by design: a grant must pair with the terminal guard, the
        # history note, and the broadcast — all lifecycle facts owned here.
        # Tests drive budget states through supervisor + provider, never by
        # reaching into this reader.
        attr_reader :budget

        def save_transcript!
          saved = TranscriptFormatter.save!(@transcript_uri, @history, @monitor)
          @transcript_path = saved
          # A failed save must not be silent: the advertised path would 404 silently.
          @last_error ||= "Transcript save failed for #{@transcript_uri}: see stderr" unless saved
        end

        def run_execution_cycle
          # Fresh runs seed; a redeployed run continues its preserved history.
          @history.push({ role: "system", content: build_effective_system_prompt }, { role: "user", content: @prompt }) if @history.empty?

          unless @provider
            @budget.consume
            @result = "Subagent [#{@id}] (#{@role}) completed task successfully: #{@prompt.slice(0, 80)}"
            transition!(:completed)
            @unit&.sync_state!
            save_transcript!
            return
          end

          execute_steps_with_provider
          @unit&.sync_state!
          save_transcript!
        rescue StateError => e
          fail_run("LIFECYCLE INVARIANT VIOLATED: #{e.class}: #{e.message}")
        rescue StandardError => e
          fail_run("#{e.class}: #{e.message}")
        end

        # The single budget-grant core (Candidate 03): terminal guard ->
        # grant -> resume -> note -> broadcast. Note wording lives in
        # Budget.grant_note/message_grant_note (audience boundary: the
        # subagent's own loop); call sites pass a lambda receiving extra +
        # new total. The budget mechanics run inside @budget.grant! under
        # the Budget lock (lock order: instance -> budget). The broadcast
        # is a harmless no-op when nobody waits. Terminal and canceling
        # states refuse the grant — a dying or dead instance must not
        # resurrect (kill's race window included).
        def grant_budget!(steps, note:)
          @monitor.synchronize do
            return false if terminal?

            extra, total = @budget.grant!(steps)
            transition!(:running)
            @history << { role: "user", content: note.call(extra, total) }
            @budget_cond.broadcast
            @error_cond.broadcast
            @unit&.sync_state!
            true
          end
        end

        def pause_and_await_budget_expansion!(wait_timeout = nil)
          payload = nil
          @monitor.synchronize do
            return false unless executing?

            transition!(:waiting_budget)
            @result = "Paused awaiting budget expansion from the maestro."
            payload = { id: @id, role: @role, state: @state, max_steps: @budget.max_steps }
            @unit&.sync_state!
          end

          # The object that owns the fact emits it (outside the monitor, so
          # subscribers never run under the instance lock).
          Notices.emit(@event_bus, Notices::BUDGET_EXHAUSTED_EVENT, payload)

          timeout = wait_timeout || (@config.respond_to?(:fetch) ? @config.fetch("subagents.budget_wait_timeout", 180) : 180) || 180
          exhausted_payload = nil
          @monitor.synchronize do
            @budget_cond.wait(timeout) if @state == :waiting_budget
            if @state == :waiting_budget
              transition!(:budget_exhausted)
              @result = "#{Notices.budget_exhausted_line(@budget.max_steps)} Budget expansion was not received from the maestro."
              exhausted_payload = { id: @id, role: @role, state: @state, max_steps: @budget.max_steps }
              @unit&.sync_state!
            end
          end

          Notices.emit(@event_bus, Notices::COMPLETED_EVENT, exhausted_payload) if exhausted_payload

          @monitor.synchronize do
            @budget_cond.wait while @state == :budget_exhausted
            return false if terminal?

            transition!(:running)
            @unit&.sync_state!
            true
          end
        end

        def pause_on_error!(error, wait_timeout = nil)
          payload = nil
          @monitor.synchronize do
            return false unless executing?

            transition!(:paused_error)
            @last_error = "#{error.class}: #{error.message}"
            @result = "Paused awaiting error recovery: #{@last_error}"
            payload = { id: @id, role: @role, state: @state, error: @last_error }
            @unit&.sync_state!
          end

          # The pause IS the recovery: a raising emit degrades to warn (door fallback), never to a terminal failure.
          Notices.emit(@event_bus, Notices::ERROR_PAUSED_EVENT, payload,
                       fallback: "[Subagent] '#{@id}' error-paused notice emit failed (#{@last_error})")

          timeout = wait_timeout ||
                    (@config.respond_to?(:fetch) && @config.fetch("subagents.error_wait_timeout", nil)) ||
                    Resilience::DEFAULT_ERROR_WAIT_TIMEOUT
          @monitor.synchronize do
            @error_cond.wait(timeout) if error_paused?
            if error_paused?
              transition!(:failed)
              @result = "Subagent halted after #{timeout}s in paused_error state: #{@last_error}"
              @unit&.sync_state!
              false
            else
              # Symmetric with the budget wake: a kill that flipped us to
              # :canceling while parked wins — the worker must not resurrect.
              return false if terminal?

              transition!(:running)
              @unit&.sync_state!
              true
            end
          end
        end

        def build_effective_system_prompt
          base = "You are a specialized subagent operating under autonomous supervision.\n\n" \
                 "Subagent ID: #{@id} | Role: #{@role} | Type: #{@type_name}\n" \
                 "Allocated Step Budget: #{@budget.max_steps} steps.\n\n" \
                 "A [Step X/Y] status line precedes each of your steps (X = current step, Y = total budget). Pace yourself: " \
                 "when remaining steps (Y - X) run low, conclude the task or prepare a progress summary for the maestro " \
                 "supervisor — it may extend your budget or steer you. If a requirement is genuinely ambiguous, ask the maestro directly with the " \
                 "ask_question tool — it blocks until the maestro answers or times out; ask only when the answer truly changes your work.\n\n" \
                 "Perform your assigned task with high precision and provide a structured synthesis report."
          @system_prompt && !@system_prompt.strip.empty? ? "#{base}\n\nCustom Instructions:\n#{@system_prompt}" : base
        end
      end
    end
  end
end
