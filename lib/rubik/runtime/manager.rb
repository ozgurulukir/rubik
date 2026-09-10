# frozen_string_literal: true

require "monitor"
require_relative "context"
require_relative "fiber"

module Rubik
  module Runtime
    class Manager
      attr_reader :context

      def initialize(context = nil)
        @context = context || Context.new
        @fibers = {}
        @monitor = Monitor.new
        # Fiber names with a factory currently in flight (reentrant reconcile
        # guard): a factory that re-provides its own dependency re-enters
        # reconcile_all on the same thread; without this marker the pending/
        # active branches would re-activate the fiber and recurse unbounded
        # (Monitor is reentrant, so the spiral ends in SystemStackError, not
        # a deadlock).
        @activating = {}
      end

      def fibers
        @monitor.synchronize { @fibers.dup }
      end

      def register_component(name, inject: [], requires: [], config: {}, &factory)
        name_str = name.to_s
        fiber = Fiber.new(name: name_str, inject: inject, requires: requires, config: config, &factory)
        register_fiber(fiber)
      end

      def register_fiber(fiber)
        @monitor.synchronize do
          @fibers[fiber.name] = fiber
          reconcile_fiber(fiber)
          fiber
        end
      end

      def unregister_component(name)
        @monitor.synchronize do
          name_str = name.to_s
          fiber = @fibers.delete(name_str)
          fiber&.dispose!
        end
      end

      def provide(service_name, service)
        @monitor.synchronize do
          @context.provide(service_name, service)
          reconcile_all(changed_service: service_name)
        end
      end

      # Reentrant lock safety: Monitor#synchronize is explicitly reentrant (recursive),
      # allowing swap_component to safely invoke unregister_component and register_component
      # from within the same thread without deadlocking.
      def swap_component(name, inject: [], config: {}, &new_factory)
        @monitor.synchronize do
          name_str = name.to_s
          unregister_component(name_str)
          register_component(name_str, inject: inject, config: config, &new_factory)
        end
      end

      def reconcile_all(changed_service: nil)
        @monitor.synchronize do
          @fibers.values.each do |fiber| # rubocop:disable Style/HashEachMethods -- snapshot array required to prevent RuntimeError when activation registers a fiber
            reconcile_fiber(fiber, changed_service: changed_service)
          end
        end
      end

      def reconcile_fiber(fiber, changed_service: nil)
        @monitor.synchronize do
          # Reentrancy guard: skip fibers whose factory is currently running
          # (nested reconcile from a factory-side provide). The in-flight
          # factory already observes the newest value it provided, so the
          # outer activation converges; a skipped re-run would only recurse.
          return if @activating.key?(fiber.name)

          case fiber.state
          when :pending
            with_activation_marker(fiber) { fiber.activate!(@context) } if fiber.ready_to_activate?(@context)
          when :active
            if !fiber.ready_to_activate?(@context)
              fiber.deactivate!
            elsif changed_service && fiber_depends_on_service?(fiber, changed_service.to_s.downcase)
              with_activation_marker(fiber) { fiber.reactivate!(@context) }
            end
          when :failed
            if fiber.ready_to_activate?(@context) # rubocop:disable Lint/DuplicateBranch -- :pending and :failed intentionally share activation reaction; state machine branches kept explicit
              with_activation_marker(fiber) { fiber.activate!(@context) }
            end
          end
        end
      end

      def active_fibers
        @monitor.synchronize do
          @fibers.values.select { |f| f.state == :active }
        end
      end

      def pending_fibers
        @monitor.synchronize do
          @fibers.values.select { |f| f.state == :pending }
        end
      end

      def failed_fibers
        @monitor.synchronize do
          @fibers.values.select { |f| f.state == :failed }
        end
      end

      def dispose!
        @monitor.synchronize do
          @fibers.values.each(&:dispose!) # rubocop:disable Style/HashEachMethods -- snapshot array required to prevent mutation during disposal iteration
          @fibers.clear
          @context.dispose
        end
      end

      private

      # Marks the fiber while its factory runs so nested reconciles skip it;
      # ensure-based so a raising factory (→ :failed) never wedges the marker.
      def with_activation_marker(fiber)
        @activating[fiber.name] = true
        begin
          yield
        ensure
          @activating.delete(fiber.name)
        end
      end

      # A fiber depends on a changed service when it injects the literal key
      # or a legacy alias of it (Rubik::Coeffects SSOT), so alias-injected
      # fibers react to canonical re-provides instead of holding stale
      # service instances.
      def fiber_depends_on_service?(fiber, changed_key)
        fiber.inject.any? { |dep| dep == changed_key || Rubik::Coeffects.canonical(dep) == changed_key }
      end
    end
  end
end
