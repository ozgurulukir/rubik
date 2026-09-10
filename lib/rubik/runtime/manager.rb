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
      end

      def fibers
        @monitor.synchronize { @fibers.dup }
      end

      def register_component(name, inject: [], config: {}, &factory)
        name_str = name.to_s
        fiber = Fiber.new(name: name_str, inject: inject, config: config, &factory)
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
          case fiber.state
          when :pending
            fiber.activate!(@context) if fiber.satisfiable?(@context)
          when :active
            if !fiber.satisfiable?(@context)
              fiber.deactivate!
            elsif changed_service && fiber_depends_on_service?(fiber, changed_service.to_s.downcase)
              fiber.reactivate!(@context)
            end
          when :failed
            fiber.activate!(@context) if fiber.satisfiable?(@context) # rubocop:disable Lint/DuplicateBranch -- :pending and :failed intentionally share activation reaction; state machine branches kept explicit
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
