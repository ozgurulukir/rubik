# frozen_string_literal: true

require_relative "context"

module Rubik
  module Runtime
    class Fiber
      STATES = [:unloaded, :pending, :active, :failed, :disposed].freeze

      attr_reader :name, :inject, :config, :state, :last_error, :sub_context, :instance

      def initialize(name:, inject: [], config: {}, &factory)
        @name = name.to_s
        @inject = Array(inject).map(&:to_s).map(&:downcase)
        @config = config || {}
        @factory = factory
        @state = :pending
        @last_error = nil
        @sub_context = nil
        @instance = nil
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
          @instance = if @factory
                        @factory.call(@sub_context, @config)
                      else
                        build_instance(@sub_context, @config)
                      end
          @state = :active
          @last_error = nil
          true
        rescue StandardError => e
          # Atomic Rollback on Error: unwind partial inverses immediately
          @sub_context.dispose if @sub_context
          @sub_context = nil
          @instance = nil
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
        @instance = nil
        @state = :pending
        true
      end

      def reactivate!(context)
        deactivate! if @state == :active
        activate!(context)
      end

      def dispose!
        deactivate! if @state == :active
        @state = :disposed
      end

      def build_instance(_sub_context, _config)
        nil
      end
    end
  end
end
