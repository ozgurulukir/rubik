# frozen_string_literal: true

require "logger"

module Rubik
  class EventBus
    def initialize(logger: Logger.new($stderr))
      @subscribers = Hash.new { |h, k| h[k] = [] }
      @logger = logger
      @mutex = Mutex.new
    end

    def subscribe(event_name, &block)
      return unless block_given?

      @mutex.synchronize do
        @subscribers[event_name.to_sym] << block
      end
    end

    def emit(event_name, payload = {})
      event_key = event_name.to_sym
      listeners = @mutex.synchronize { @subscribers[event_key].dup }

      listeners.each do |listener|
        listener.call(payload)
      rescue StandardError => e
        @logger.error("EventBus subscriber error on event '#{event_name}': #{e.message}")
      end
    end
  end
end
