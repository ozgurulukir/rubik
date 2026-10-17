# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Owns the parked worker gate used to make subagent startup reversible.
      module StartGate
        def start_async(defer_start: false, &on_complete)
          run_gate = Queue.new
          @monitor.synchronize do
            return false if @thread&.alive?

            @started_at = Time.now
            @run_seq += 1
            @start_aborted = false
            @start_gate = run_gate
            transition!(:running)
            @unit&.sync_state!
          end

          ready = Queue.new
          thread = Thread.new do
            Thread.handle_interrupt(Object => :never) do
              ready << true # cleanup is armed before cancellation is enabled
              Thread.handle_interrupt(Object => :immediate) do
                run_execution_cycle if run_gate.pop == :start
              end
            ensure
              aborted = @monitor.synchronize { @start_aborted }
              @ended_at ||= Time.now
              if aborted
                cleanup_context
              else
                @journal&.record_run_finished(run: @run_seq, state: @state.to_s, result: @result,
                                              result_ref: (result_ref if settled?))
                save_transcript! if @transcript_path.nil?
                @cancelled_by_operator ? cleanup : cleanup_context
                on_complete&.call(self)
              end
            end
          end
          @monitor.synchronize { @thread = thread }
          ready.pop
          release_start! unless defer_start
          true
        rescue StandardError
          abort_start!
          raise
        end

        # The spawn transaction releases the worker only after every
        # fallible registration step has completed.
        def release_start!
          @monitor.synchronize do
            return false unless @start_gate && !@start_aborted

            @journal&.record_run_started(run: @run_seq, role: @role, type: @type_name, prompt: @prompt)
            @start_gate << :start
            @start_gate = nil
          end
          true
        end

        def abort_start!
          thread = @monitor.synchronize do
            @start_aborted = true
            gate = @start_gate
            @start_gate = nil
            gate << :abort if gate
            @thread
          end

          if thread && thread != Thread.current
            thread.join(0.5)
            if thread.alive?
              thread.kill
              thread.join
            end
          end
          cleanup_context
          true
        end
      end
    end
  end
end
