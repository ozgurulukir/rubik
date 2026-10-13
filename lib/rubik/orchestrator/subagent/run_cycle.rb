# frozen_string_literal: true

require_relative "transcript_formatter"
require_relative "narration"

module Rubik
  module Orchestrator
    module Subagent
      # The per-run entry/exit choreography, extracted from Instance to keep
      # it under its module-hygiene cap (issue #122 added the run-sequence
      # reference plumbing there): history seeding, the nil-provider terminal
      # stub, the single failure drain, effective-prompt assembly and the
      # durable transcript save belong to ONE vertical slice — a fresh run and
      # a redeploy both enter through run_execution_cycle.
      module RunCycle
        private

        def run_execution_cycle
          # Fresh runs seed; a redeployed run continues its preserved history.
          @history.push({ role: "system", content: build_effective_system_prompt }, { role: "user", content: @prompt }) if @history.empty?

          unless @provider
            @budget.consume
            @result = Narration.completed_stub_line(@id, @role, @prompt)
            transition!(:completed)
            @unit&.sync_state!
            save_transcript!
            return
          end

          execute_steps_with_provider
          @unit&.sync_state!
          save_transcript!
        rescue Lifecycle::StateError => e
          fail_run("LIFECYCLE INVARIANT VIOLATED: #{e.class}: #{e.message}")
        rescue StandardError => e
          fail_run("#{e.class}: #{e.message}")
        end

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

        # Private by design: the transcript URI is minted once at construction
        # and every save mirrors the in-memory history (redacted at the file
        # boundary) — callers own the retention decision, not the path.
        def save_transcript!
          saved = TranscriptFormatter.save!(@transcript_uri, @history, @monitor,
                                            prompt_reconstructible: @prompt_reconstructible)
          @transcript_path = saved
          # A failed save must not be silent: the advertised path would 404 silently.
          @last_error ||= "Transcript save failed for #{@transcript_uri}: see stderr" unless saved
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
