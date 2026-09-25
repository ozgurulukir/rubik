# frozen_string_literal: true

require "monitor"

module Rubik
  module Kernel
    # Deterministic sequential FIFO event dispatcher with worker queue (Plan 103).
    # Backed by Thread::Queue and a dedicated kworker daemon.
    # Dispatches events sequentially, logs to Dmesg ring buffer, and guarantees
    # subscriber error isolation.
    class Dispatcher
      STOP_MARKER = :__dispatcher_stop__

      Event = Struct.new(:name, :payload, :subsystem, :level, :facility_id, keyword_init: true)
      Barrier = Struct.new(:queue)

      attr_reader :dmesg, :worker_thread

      def initialize(dmesg: nil, logger: nil)
        @dmesg = dmesg
        @logger = logger
        @queue = Thread::Queue.new
        @listeners = Hash.new { |h, k| h[k] = [] }
        @lock = Monitor.new
        @stopped = false
        @worker_thread = Thread.new { process_queue }
        @worker_thread.name = "rubik-kworker" if @worker_thread.respond_to?(:name=)
      end

      def post(event_name, payload = {}, subsystem: :kernel, level: :info, facility_id: nil, **kwargs)
        return false if stopped?

        eff_payload = if kwargs.empty?
                        payload || {}
                      elsif payload.is_a?(Hash)
                        payload.merge(kwargs)
                      else
                        kwargs
                      end

        @queue.push(
          Event.new(
            name: event_name.to_sym, payload: eff_payload,
            subsystem: subsystem.to_sym, level: level, facility_id: facility_id
          )
        )
        true
      end

      def subscribe(event_name, context: nil, &block)
        return unless block_given?

        @lock.synchronize { @listeners[event_name.to_sym] << block }
        context.on_dispose { unsubscribe(event_name, block) } if context.respond_to?(:on_dispose)
        block
      end

      def unsubscribe(event_name_or_listener, listener = nil)
        @lock.synchronize do
          if listener.nil?
            @listeners.each_value { |list| list.delete(event_name_or_listener) } if event_name_or_listener
          elsif listener
            @listeners[event_name_or_listener.to_sym].delete(listener)
          end
        end
        nil
      end

      def sync_drain(timeout = 2.0)
        return true if !worker_alive? || Thread.current == @worker_thread

        barrier = Barrier.new(Thread::Queue.new)
        @queue.push(barrier)
        !barrier.queue.pop(timeout: timeout).nil?
      end

      def stop(timeout = 2.0)
        @lock.synchronize do
          return true if @stopped

          @stopped = true
        end

        sync_drain(timeout) unless Thread.current == @worker_thread
        @queue.push(STOP_MARKER)
        if @worker_thread && Thread.current != @worker_thread
          @worker_thread.join(timeout)
          @worker_thread.kill if @worker_thread.alive?
          @worker_thread = nil
        end
        true
      end
      alias dispose stop

      def stopped?
        @lock.synchronize { @stopped }
      end

      def alive?
        !stopped? && worker_alive?
      end

      def worker_alive?
        !@worker_thread.nil? && @worker_thread.alive?
      end

      def subscribers(event_name)
        @lock.synchronize { @listeners[event_name.to_sym].dup }
      end

      def all_subscribers
        @lock.synchronize { @listeners.transform_values(&:dup) }
      end

      def queue_size
        @queue.size
      end

      private

      def process_queue
        loop do
          item = @queue.pop
          break if item == STOP_MARKER

          if item.is_a?(Barrier)
            item.queue.push(true)
            next
          end

          dispatch_event(item)
        rescue StandardError => e
          @logger&.error("Dispatcher worker error: #{e.message}")
        end
      end

      def dispatch_event(event)
        log_to_dmesg(event)
        listeners = @lock.synchronize { @listeners[event.name].dup }
        listeners.each { |l| invoke_listener(l, event) }
      end

      def invoke_listener(listener, event)
        listener.arity.zero? ? listener.call : listener.call(event.payload)
      rescue StandardError => e
        begin
          @dmesg&.log(:kernel, :err, "Subscriber error on #{event.name}: #{e.message}")
        rescue StandardError
          nil
        end
        @logger&.error("EventBus subscriber error on event '#{event.name}': #{e.message}")
      end

      def log_to_dmesg(event)
        return unless @dmesg

        data = event.payload.is_a?(Hash) ? event.payload.dup : { value: event.payload }
        fac_id = data.delete(:facility_id) || event.facility_id
        safe_data = {}
        data.each do |k, v|
          safe_data[k.to_sym] = v
        rescue StandardError
          nil
        end
        @dmesg.log(event.subsystem, event.level, "event:#{event.name}", facility_id: fac_id, **safe_data)
      rescue StandardError => e
        @logger&.error("Dispatcher dmesg logging error: #{e.message}")
      end
    end
  end
end
