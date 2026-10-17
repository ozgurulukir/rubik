# frozen_string_literal: true

require "monitor"
require_relative "unit"

module Rubik
  module Kernel
    # Root lifecycle supervisor (PID 1) governing all kernel execution units (Plan 104).
    # Single source of truth for background execution, zombie reaping, and LIFO shutdown.
    class Init
      attr_reader :context, :dmesg, :dispatcher

      def initialize(context: nil, dmesg: nil, dispatcher: nil)
        @context = context
        @dmesg = dmesg
        @dispatcher = dispatcher
        @units = {}
        @order = []
        @monitor = Monitor.new
        @stopped = false

        bind_context(@context)
      end

      def register(unit)
        @monitor.synchronize do
          raise ArgumentError, "Unit cannot be nil" if unit.nil?
          raise Unit::StateError, "Init supervisor is stopped" if @stopped

          unit.dmesg ||= @dmesg if unit.respond_to?(:dmesg=)
          unit.dispatcher ||= @dispatcher if unit.respond_to?(:dispatcher=)

          @units[unit.id] = unit
          @order << unit.id unless @order.include?(unit.id)
          @dmesg&.log(:kernel, :info, "registered unit:#{unit.id} type:#{unit.type}", facility_id: "init", unit_id: unit.id)
          unit
        end
      end

      # Remove a unit only when it is still the exact object registered by
      # this activation. Spawn rollback must not erase a newer same-id unit.
      def unregister(unit)
        return false if unit.nil? || !unit.respond_to?(:id)

        @monitor.synchronize do
          id = unit.id.to_s
          return false unless @units[id].equal?(unit)

          @units.delete(id)
          @order.delete(id)
          true
        end
      end
      alias spawn register

      def get(id)
        @monitor.synchronize do
          unit = @units[id.to_s]
          unit&.sync_state! if unit.respond_to?(:sync_state!)
          unit
        end
      end
      alias [] get

      def units
        @monitor.synchronize do
          @units.each_value { |u| u.sync_state! if u.respond_to?(:sync_state!) }
          @units.values.dup
        end
      end

      def units_by_state(*states)
        target_states = states.flatten.map(&:to_sym)
        @monitor.synchronize do
          @units.values.select do |u|
            u.sync_state! if u.respond_to?(:sync_state!)
            target_states.include?(u.state)
          end
        end
      end

      def size
        @monitor.synchronize { @units.size }
      end

      def empty?
        @monitor.synchronize { @units.empty? }
      end

      def reap_dead_units!
        @monitor.synchronize do
          reaped = []
          @units.each_value do |unit|
            unit.sync_state! if unit.respond_to?(:sync_state!)
            next unless unit.dead? && unit.state != :reaped

            safely_dispose_context(unit)
            unit.transition_to!(:reaped, reason: "reaped")
            reaped << unit
          end
          @dmesg&.log(:kernel, :info, "reaped #{reaped.size} dead units", facility_id: "init") unless reaped.empty?
          reaped
        end
      end

      def kill(id, reason = "killed")
        @monitor.synchronize do
          unit = @units[id.to_s]
          return false unless unit

          safely_kill_unit(unit, reason)
          true
        end
      end

      def kill_all(reason = "killed")
        @monitor.synchronize do
          # LIFO shutdown: reverse chronological order of registered units
          @order.reverse_each do |id|
            unit = @units[id]
            next unless unit

            safely_kill_unit(unit, reason)
          end
          true
        end
      end

      def resume_all
        @monitor.synchronize do
          resumed = []
          @units.each_value do |unit|
            unit.sync_state! if unit.respond_to?(:sync_state!)
            next unless unit.paused?

            begin
              unit.respond_to?(:resume) ? unit.resume : unit.transition_to!(:active, reason: "resumed")
              resumed << unit
            rescue StandardError => e
              @dmesg&.log(:kernel, :warn, "failed to resume unit:#{unit.id}: #{e.message}", facility_id: "init")
            end
          end
          resumed
        end
      end

      def stop
        @monitor.synchronize do
          return true if @stopped

          @stopped = true
        end

        kill_all("init_stopped")
        reap_dead_units!
        @dmesg&.log(:kernel, :info, "init stopped; all units reaped", facility_id: "init")
        true
      end
      alias dispose stop

      def stopped?
        @monitor.synchronize { @stopped }
      end

      private

      def safely_kill_unit(unit, reason)
        return if unit.dead?

        if unit.respond_to?(:kill)
          unit.kill(reason)
        elsif unit.active? || unit.paused? || unit.pending?
          unit.transition_to!(:failed, reason: reason)
        end
      rescue StandardError => e
        @dmesg&.log(:kernel, :warn, "error killing unit:#{unit.id}: #{e.message}", facility_id: "init")
      end

      def safely_dispose_context(unit)
        unit.context&.dispose if unit.context.respond_to?(:dispose)
      rescue StandardError => e
        @dmesg&.log(:kernel, :warn, "error disposing context for unit:#{unit.id}: #{e.message}", facility_id: "init")
      end

      def bind_context(ctx)
        return unless ctx.respond_to?(:on_dispose)

        ctx.on_dispose { stop }
      end
    end
  end
end
