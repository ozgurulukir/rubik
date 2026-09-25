# frozen_string_literal: true

require "logger"
require_relative "kernel/dispatcher"

module Rubik
  # Event bus facade bridging to Rubik::Kernel::Dispatcher (Plan 103).
  # Provides deterministic FIFO event processing, Dmesg integration, and fault isolation
  # while maintaining 100% backward compatibility for subscribe, unsubscribe, emit, and drain!.
  class EventBus
    attr_reader :dispatcher

    def initialize(dispatcher: nil, logger: Logger.new($stderr))
      @logger = logger
      @dispatcher = dispatcher || Rubik::Kernel::Dispatcher.new(logger: @logger)
    end

    def dispatcher=(new_dispatcher)
      return if @dispatcher == new_dispatcher

      old_dispatcher = @dispatcher
      if old_dispatcher && new_dispatcher && old_dispatcher.respond_to?(:all_subscribers)
        old_dispatcher.all_subscribers.each do |event_name, procs|
          procs.each { |pr| new_dispatcher.subscribe(event_name, &pr) }
        end
      end
      @dispatcher = new_dispatcher
      old_dispatcher&.stop
    end

    def subscribe(event_name, context: nil, &)
      @dispatcher.subscribe(event_name, context: context, &)
    end

    def unsubscribe(event_name, listener)
      @dispatcher.unsubscribe(event_name, listener)
    end

    def post(event_name, payload = {}, subsystem: :kernel, level: :info, facility_id: nil, **)
      @dispatcher.post(event_name, payload, subsystem: subsystem, level: level, facility_id: facility_id, **)
    end

    def emit(event_name, payload = {}, **)
      post(event_name, payload, **)
      drain!
    end

    def drain!(timeout = 2.0)
      @dispatcher.sync_drain(timeout)
    end

    def stop(timeout = 2.0)
      @dispatcher.stop(timeout)
    end
  end
end
