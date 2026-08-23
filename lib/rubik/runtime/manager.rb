# frozen_string_literal: true

require_relative "context"
require_relative "fiber"

module Rubik
  module Runtime
    class Manager
      attr_reader :context, :fibers

      def initialize(context = nil)
        @context = context || Context.new
        @fibers = {}
      end

      def register_component(name, inject: [], config: {}, &factory)
        name_str = name.to_s
        fiber = Fiber.new(name: name_str, inject: inject, config: config, &factory)
        @fibers[name_str] = fiber

        reconcile_fiber(fiber)
        fiber
      end

      def unregister_component(name)
        name_str = name.to_s
        fiber = @fibers.delete(name_str)
        return unless fiber

        fiber.dispose!
      end

      def provide(service_name, service)
        @context.provide(service_name, service)
        reconcile_all
      end

      def swap_component(name, inject: [], config: {}, &new_factory)
        name_str = name.to_s
        unregister_component(name_str)
        register_component(name_str, inject: inject, config: config, &new_factory)
      end

      def reconcile_all
        @fibers.each_value do |fiber|
          reconcile_fiber(fiber)
        end
      end

      def reconcile_fiber(fiber)
        if fiber.state == :pending
          fiber.activate!(@context) if fiber.satisfiable?(@context)
        elsif fiber.state == :active
          fiber.deactivate! unless fiber.satisfiable?(@context)
        end
      end

      def active_fibers
        @fibers.values.select { |f| f.state == :active }
      end

      def pending_fibers
        @fibers.values.select { |f| f.state == :pending }
      end

      def dispose!
        @fibers.each_value(&:dispose!)
        @fibers.clear
        @context.dispose
      end
    end
  end
end
