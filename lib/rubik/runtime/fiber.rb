# frozen_string_literal: true

require_relative "context"

module Rubik
  module Runtime
    class Fiber
      STATES = %i[unloaded pending active failed disposed].freeze

      attr_reader :name, :inject, :config, :state, :last_error, :sub_context

      def initialize(name:, inject: [], config: {}, &factory)
        @name = name.to_s
        @inject = Array(inject).map(&:to_s).map(&:downcase)
        @config = config || {}
        @factory = factory
        @state = :pending
        @last_error = nil
        @sub_context = nil
      end

      def satisfiable?(context)
        @inject.all? { |dep| context.has?(dep) }
      end

      def activate!(context)
        return true if @state == :active
        return false unless satisfiable?(context)

        # Scoped sub-context for fiber lifecycle
        @sub_context = context.extend

        begin
          @factory.call(@sub_context, @config) if @factory
          @state = :active
          @last_error = nil
          true
        rescue StandardError => e
          # Atomic Rollback on Error: unwind partial inverses immediately
          @sub_context.dispose if @sub_context
          @sub_context = nil
          @state = :failed
          @last_error = e
          false
        end
      end

      def deactivate!
        return false unless @state == :active

        if @sub_context
          @sub_context.dispose
          @sub_context = nil
        end
        @state = :pending
        true
      end

      def dispose!
        deactivate! if @state == :active
        @state = :disposed
      end
    end
  end
end
