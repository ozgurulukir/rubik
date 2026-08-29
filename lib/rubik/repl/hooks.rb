# frozen_string_literal: true

require "logger"

module Rubik
  module REPL
    class Hooks
      KNOWN_EVENTS = [:file_changed, :test_failed, :before_command, :after_command].freeze

      def initialize(logger: Logger.new($stderr))
        @hooks = Hash.new { |h, k| h[k] = [] }
        @logger = logger
      end

      def register(event_name, &block)
        return unless block_given?

        event_key = event_name.to_sym
        @hooks[event_key] << block
      end

      def trigger(event_name, *args)
        event_key = event_name.to_sym
        @hooks[event_key].each do |hook|
          hook.call(*args)
        rescue StandardError => e
          @logger.error("Hook error on event '#{event_name}': #{e.message}")
        end
      end
    end
  end
end
