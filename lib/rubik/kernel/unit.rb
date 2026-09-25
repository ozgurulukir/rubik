# frozen_string_literal: true

require "monitor"

module Rubik
  module Kernel
    # Kernel execution unit representing an asynchronous computation (Plan 104).
    class Unit
      class StateError < StandardError; end

      VALID_TYPES = [:subagent, :process, :task, :service].freeze
      VALID_STATES = [:pending, :active, :paused_error, :waiting_budget, :completed, :failed, :reaped].freeze
      TERMINAL_STATES = [:completed, :failed, :reaped].freeze
      PAUSED_STATES = [:paused_error, :waiting_budget].freeze

      attr_reader :id, :type, :state, :context, :facility_id, :created_at, :started_at, :finished_at, :reason
      attr_accessor :dmesg, :dispatcher

      def initialize(id:, type:, context: nil, facility_id: nil, state: :pending, dmesg: nil, dispatcher: nil, reason: nil)
        @id = id.to_s
        @type = type.to_sym
        @context = context
        @reason = reason
        @state = state.to_sym
        @facility_id = facility_id || @id
        @created_at = Time.now
        @started_at = (Time.now if @state == :active)
        @finished_at = (Time.now if dead?)
        @dmesg = dmesg
        @dispatcher = dispatcher
        @monitor = Monitor.new
      end

      def transition_to!(new_state, reason: nil)
        @monitor.synchronize do
          target = new_state.to_sym
          raise ArgumentError, "Invalid state: #{target}" unless VALID_STATES.include?(target)
          return self if @state == target

          raise StateError, "Terminal :reaped cannot transition to :#{target}" if @state == :reaped
          raise StateError, "Terminal :#{@state} can only transition to :reaped, not :#{target}" if [:completed, :failed].include?(@state) && target != :reaped

          old_state = @state
          @state = target
          @reason = reason || @reason
          @started_at ||= Time.now if target == :active
          @finished_at ||= Time.now if TERMINAL_STATES.include?(target)
          notify_transition(old_state, target, reason)
          self
        end
      end

      def active? = @state == :active
      def running? = active?
      def pending? = @state == :pending
      def paused? = PAUSED_STATES.include?(@state)
      def dead? = TERMINAL_STATES.include?(@state)
      def reaped? = @state == :reaped
      def uptime = @started_at ? ((@finished_at || Time.now) - @started_at).to_f : 0.0

      def kill(reason = "killed")
        stop_underlying
        transition_to!(:failed, reason: reason) if active? || paused? || pending?
      end

      def resume(additional_steps: 10)
        resume_underlying(additional_steps)
        transition_to!(:active, reason: "resumed") if paused?
      end

      def sync_state!
        return @state if dead?

        new_st = underlying_state
        transition_to!(new_st) if new_st && new_st != @state
        @state
      end

      def to_h
        { id: @id, type: @type, state: @state, facility_id: @facility_id,
          uptime: uptime.round(2), created_at: @created_at, started_at: @started_at,
          finished_at: @finished_at, reason: @reason }
      end

      private

      def stop_underlying; end
      def resume_underlying(_steps); end
      def underlying_state = nil

      def notify_transition(from_state, to_state, reason)
        suffix = reason ? " (#{reason})" : ""
        msg = "unit:#{@id} state transition #{from_state} -> #{to_state}#{suffix}"
        @dmesg&.log(:kernel, :info, msg, facility_id: @facility_id, unit_id: @id, from_state: from_state, to_state: to_state)
        @dispatcher&.post(:unit_state_changed, unit_id: @id, type: @type, from_state: from_state,
                                               to_state: to_state, reason: reason, facility_id: @facility_id)
      end
    end

    # Unit wrapper for managed child background processes (TaskManager tasks).
    class ProcessUnit < Unit
      STATUS_MAP = { running: :active, completed: :completed, failed: :failed, killed: :failed }.freeze

      attr_reader :task, :task_manager

      def initialize(task_or_id, task_manager: nil, context: nil, dmesg: nil, dispatcher: nil, **kwargs)
        @task = task_or_id.respond_to?(:id) ? task_or_id : kwargs[:task]
        @task_manager = task_manager
        id = @task ? @task.id : task_or_id
        st = @task ? STATUS_MAP.fetch(@task.status, :pending) : kwargs.fetch(:state, :pending)
        super(id: id, type: :process, context: context, facility_id: "process-#{id}",
              state: st, dmesg: dmesg, dispatcher: dispatcher, **kwargs)
        @started_at = @task.started_at if @task
        @finished_at = @task.ended_at if @task
      end

      private

      def stop_underlying = @task_manager&.kill(@id)
      def underlying_state = (@task ? STATUS_MAP.fetch(@task.status, :pending) : nil)
    end

    # Unit wrapper for autonomous subagents (Subagent::Instance).
    class SubagentUnit < Unit
      STATE_MAP = { running: :active, waiting_input: :active, waiting_budget: :waiting_budget,
                    paused_error: :paused_error, completed: :completed, failed: :failed, canceled: :failed }.freeze

      attr_reader :instance

      def initialize(inst_or_id, context: nil, dmesg: nil, dispatcher: nil, **kwargs)
        @instance = inst_or_id.respond_to?(:id) ? inst_or_id : kwargs[:instance]
        id = @instance ? @instance.id : inst_or_id
        st = @instance ? STATE_MAP.fetch(@instance.state, :pending) : kwargs.fetch(:state, :pending)
        ctx = context || (@instance.context if @instance.respond_to?(:context))
        super(id: id, type: :subagent, context: ctx, facility_id: "subagent-#{id}",
              state: st, dmesg: dmesg, dispatcher: dispatcher, **kwargs)
        @started_at = @instance.started_at if @instance
        @finished_at = @instance.ended_at if @instance
      end

      private

      def stop_underlying = (@instance&.kill if @instance.respond_to?(:kill))
      def resume_underlying(steps) = (@instance.resume!(additional_steps: steps) if @instance.respond_to?(:resume!))
      def underlying_state = (@instance ? STATE_MAP.fetch(@instance.state, :pending) : nil)
    end
  end
end
