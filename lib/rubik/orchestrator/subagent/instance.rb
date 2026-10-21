# frozen_string_literal: true

require "monitor"
require_relative "transcript_formatter"
require_relative "start_gate"
require_relative "storage_id"
require_relative "lifecycle"
require_relative "step_runner"
require_relative "run_cycle"
require_relative "journal"
require_relative "teardown"
require_relative "operation_tracker"
require_relative "budget"
require_relative "questioner"
require_relative "reuse"
require_relative "notices"
require_relative "narration"
require_relative "resilience"
require_relative "../../prompt"
require_relative "../../uris"

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
        include RunCycle
        include StartGate
        include Teardown
        include Questioner
        include Redeploy
        include Reaper

        attr_accessor :parent_id, :unit, :owner_task
        # `state`: the sanctioned raw reader — display/serialization/kernel
        # bridge only; control flow asks the Lifecycle predicates. `result`
        # is TERMINAL-ONLY (real report / nil-provider stub); pauses narrate
        # through #state_note — derived, nothing stored to go stale (B3).
        attr_reader :id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :context, :tool_registry, :buffer_manager,
                    :profile_snapshot,
                    :state, :started_at, :ended_at, :result,
                    :last_error, :storage_id, :transcript_uri, :history,
                    :context_limit, :max_output_tokens, :config, :pause_facts, :prompt_reconstructible,
                    :run_seq, :journal, :operations

        # Budget delegation: step counters live in Subagent::Budget (reader contract preserved).
        def current_step = @budget.current_step
        def max_steps = @budget.max_steps
        def max_total_steps = @budget.max_total_steps

        def initialize(id:, parent_id:, role:, type_name:, prompt:, context:, tool_registry:,
                       system_prompt: nil, workspace: "inherit", model: "inherit",
                       provider: nil, buffer_manager: nil, max_steps: Budget::DEFAULT_MAX_STEPS, root_dir: Dir.pwd,
                       context_limit: nil, config: nil, event_bus: nil, provider_gate: nil, transcript_storage: nil,
                       prompt_reconstructible: false, owner_task: nil, profile_snapshot: nil)
          @id = id.to_s
          @parent_id = parent_id.to_s
          @role = role.to_s.strip
          @type_name = type_name.to_s.downcase.strip
          @prompt = prompt.to_s.strip
          @system_prompt = system_prompt.nil? ? nil : system_prompt.to_s.dup.freeze
          @profile_snapshot = profile_snapshot
          @prompt_reconstructible = prompt_reconstructible # spawn kararı: kurulabilir prompt → kalıcı kopya stub'a iner
          @workspace = workspace.to_s.downcase.strip
          @model = model
          @context = context
          @tool_registry = tool_registry
          @provider = provider
          @buffer_manager = buffer_manager
          max_total_steps = if config.is_a?(Hash)
                              config["subagents.max_total_steps"] || config.dig("subagents", "max_total_steps") ||
                                Budget::DEFAULT_MAX_TOTAL_STEPS
                            elsif config.respond_to?(:fetch)
                              config.fetch("subagents.max_total_steps", Budget::DEFAULT_MAX_TOTAL_STEPS)
                            else
                              Budget::DEFAULT_MAX_TOTAL_STEPS
                            end
          @budget = Budget.new(max_steps: max_steps, max_total_steps: max_total_steps)
          @root_dir = root_dir
          @config = config
          @event_bus = event_bus
          @provider_gate = provider_gate
          @context_limit = (context_limit || (@config.respond_to?(:fetch) ? @config.fetch("context.max_tokens", 32_768) : 32_768) || 32_768).to_i
          @max_output_tokens = (@config.respond_to?(:fetch) ? @config.fetch("llm.default_max_output_tokens", 4_096) : 4_096).to_i

          @state = :pending
          @history = []
          @inbox = Queue.new
          @owner_task = owner_task # issue #125: nil = explicitly detached (survives ^C)
          @cancelled_by_operator = false
          # Operation telemetry (issue #126): current operation + model/tool
          # buckets, monotonic-clock based.
          @operations = OperationTracker.new
          @started_at = @ended_at = @result = @last_error = @transcript_path = @pause_facts = nil
          # Each run (initial or redeploy) owns a sequence number: it keys the
          # retained-result reference so an earlier run's result is never
          # overwritten by its redeploy (issue #122).
          @run_seq = 0
          # Grant telemetry (session review B4/B11): grants consumed this run —
          # the halt message says "no FURTHER expansion" only when one landed.
          @grants_received = 0
          # SSOT (Plan 110): minted once; absorb (transcript_storage) kökü değiştirir.
          @storage_id = StorageId.mint(@id)
          @transcript_uri = TranscriptFormatter.mint_path(@root_dir, @storage_id, storage: transcript_storage)
          # Append-only execution journal (issue #124): lands beside the
          # transcript (absorbed or classic root), survives compaction and
          # redeploys, bounded by subagents.journal.max_bytes.
          @journal = Journal.new(path: File.join(File.dirname(@transcript_uri), Journal::FILENAME), config: @config)
          @monitor = Monitor.new
          @budget_cond = @monitor.new_cond
          @error_cond = @monitor.new_cond
          @context_cleaned_up = false
          @thread = nil
          @start_gate = nil
          @start_aborted = false
        end

        def uptime = @started_at ? ((@ended_at || Time.now) - @started_at).to_f : 0.0

        # Execution-specific canonical reference to this run's retained result
        # (issue #122): stable across reaping; the result archive answers
        # explicitly when the run was never retained, evicted, or expired.
        def result_ref
          Rubik::Uris.subagent_result(@storage_id, run: @run_seq)
        end

        # Canonical transcript read reference (issue #123): ONE address for
        # live memory and the persisted snapshot — the reader reports which
        # snapshot it served. Bare display ids are not addresses.
        def transcript_ref
          Rubik::Uris.subagent_transcript(@storage_id)
        end

        # Immutable sequence snapshot under the instance lock: the read side of
        # the transcript contract pages over a stable copy while the worker
        # keeps appending (entries themselves are append-only after write).
        def history_snapshot
          @monitor.synchronize { @history.dup }
        end

        # Diagnostic pointers (issue #124): the append-only journal path and
        # its last persistence failure (nil while healthy) — a failed journal
        # write must be observable, never silently dropped.
        def journal_path = @journal&.path
        def journal_error = @journal&.last_error

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
              @pause_facts = nil
              # Error-resume grants ride the same accounting as budget grants
              # (review B4): counted, noted to the subagent's own loop — the
              # halt message must not later claim no grant ever arrived.
              grant_budget!(additional_steps, note: ->(extra, total) { Budget.grant_note(extra, total) }) if additional_steps&.to_i&.positive?
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

        def to_h
          @monitor.synchronize do
            { id: @id, parent_id: @parent_id, role: @role, type: @type_name, state: @state.to_s,
              **@budget.to_h, max_total_steps: @budget.max_total_steps,
              grants_received: @grants_received, run: @run_seq,
              result_ref: result_ref, owner: @owner_task&.id, detached: @owner_task.nil?, uptime_seconds: uptime.round(2),
              operation: operations.current, timings: operations.timings,
              last_progress_seconds_ago: operations.last_progress_seconds_ago,
              started_at: @started_at&.iso8601, ended_at: @ended_at&.iso8601,
              transcript: @transcript_uri, transcript_ref: transcript_ref,
              journal: journal_path, journal_error: journal_error, last_error: @last_error,
              result_summary: @result&.to_s&.slice(0, 100), result: @result, state_note: state_note }
          end
        end

        # Derived narration (Narration seam): computed on demand, never stored.
        def state_note
          @monitor.synchronize do
            Narration.state_note(@state, grants_received: @grants_received, max_steps: @budget.max_steps,
                                         last_error: @last_error, paused_after_s: @pause_facts&.dig(:timeout))
          end
        end

        private

        # Private by design: a grant must pair with the terminal guard, the
        # history note, and the broadcast — all lifecycle facts owned here.
        # Tests drive budget states through supervisor + provider, never by
        # reaching into this reader.
        attr_reader :budget

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
            return false if extra.zero?

            transition!(:running)
            @grants_received += 1
            @pause_facts = nil # the wake retires the wait fact with the pause (B3's clearer, now fact-only)
            @history << { role: "user", content: note.call(extra, total) }
            @budget_cond.broadcast
            @error_cond.broadcast
            @unit&.sync_state!
            true
          end
        end

        def pause_and_await_budget_expansion!(wait_timeout = nil)
          timeout = wait_timeout || (@config.respond_to?(:fetch) ? @config.fetch("subagents.budget_wait_timeout", 180) : 180) || 180
          payload = nil
          @monitor.synchronize do
            return false unless executing?

            transition!(:waiting_budget)
            @pause_facts = { timeout: timeout }.freeze
            payload = { id: @id, role: @role, state: @state, max_steps: @budget.max_steps,
                        grants: @grants_received, step: @budget.current_step }
            @unit&.sync_state!
          end

          # The object that owns the fact emits it (outside the monitor, so
          # subscribers never run under the instance lock).
          Notices.emit(@event_bus, Notices::BUDGET_EXHAUSTED_EVENT, payload)

          exhausted_payload = nil
          @monitor.synchronize do
            @budget_cond.wait(timeout) if @state == :waiting_budget
            if @state == :waiting_budget
              transition!(:budget_exhausted)
              exhausted_payload = { id: @id, role: @role, state: @state, max_steps: @budget.max_steps,
                                    grants: @grants_received, step: @budget.current_step }
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
          timeout = wait_timeout ||
                    (@config.respond_to?(:fetch) && @config.fetch("subagents.error_wait_timeout", nil)) ||
                    Resilience::DEFAULT_ERROR_WAIT_TIMEOUT
          payload = nil
          @monitor.synchronize do
            return false unless executing?

            transition!(:paused_error)
            @last_error = "#{error.class}: #{error.message}"
            @pause_facts = { timeout: timeout }.freeze
            payload = { id: @id, role: @role, state: @state, error: @last_error }
            @unit&.sync_state!
          end

          # The pause IS the recovery: a raising emit degrades to warn (door fallback), never to a terminal failure.
          Notices.emit(@event_bus, Notices::ERROR_PAUSED_EVENT, payload,
                       fallback: "[Subagent] '#{@id}' error-paused notice emit failed (#{@last_error})")

          @monitor.synchronize do
            @error_cond.wait(timeout) if error_paused?
            if error_paused?
              transition!(:failed)
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
      end
    end
  end
end
