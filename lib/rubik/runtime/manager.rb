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
        register_fiber(fiber)
      end

      def register_fiber(fiber)
        @fibers[fiber.name] = fiber
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
        reconcile_all(changed_service: service_name)
      end

      def swap_component(name, inject: [], config: {}, &new_factory)
        name_str = name.to_s
        unregister_component(name_str)
        register_component(name_str, inject: inject, config: config, &new_factory)
      end

      def reconcile_all(changed_service: nil)
        @fibers.each_value do |fiber|
          reconcile_fiber(fiber, changed_service: changed_service)
        end
      end

      def reconcile_fiber(fiber, changed_service: nil)
        case fiber.state
        when :pending
          fiber.activate!(@context) if fiber.satisfiable?(@context)
        when :active
          if !fiber.satisfiable?(@context)
            fiber.deactivate!
          elsif changed_service && fiber.inject.include?(changed_service.to_s.downcase)
            fiber.reactivate!(@context)
          end
        when :failed
          # rubocop:disable Lint/DuplicateBranch -- :pending ve :failed bilinçli olarak aynı tepkiyi verir; durum makinesi dalları ayrı kalmalı
          fiber.activate!(@context) if fiber.satisfiable?(@context)
          # rubocop:enable Lint/DuplicateBranch
        end
      end

      def active_fibers
        @fibers.values.select { |f| f.state == :active }
      end

      def pending_fibers
        @fibers.values.select { |f| f.state == :pending }
      end

      def failed_fibers
        @fibers.values.select { |f| f.state == :failed }
      end

      def dispose!
        @fibers.each_value(&:dispose!)
        @fibers.clear
        @context.dispose
      end
    end
  end
end
