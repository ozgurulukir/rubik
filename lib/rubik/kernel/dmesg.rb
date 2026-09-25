# frozen_string_literal: true

require "monitor"
require_relative "record"

module Rubik
  module Kernel
    # Bounded circular ring buffer for monotonic kernel event telemetry (Plan 102).
    # Zero memory growth: pre-allocated array overwritten in O(1) time.
    class Dmesg
      DEFAULT_CAPACITY = 2048

      attr_reader :capacity, :seq_counter, :start_time

      def initialize(capacity: DEFAULT_CAPACITY)
        @capacity = [capacity.to_i, 1].max
        @buffer = Array.new(@capacity)
        @head = 0
        @size = 0
        @seq_counter = 0
        @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @monitor = Monitor.new
      end

      def size
        @monitor.synchronize { @size }
      end

      def empty?
        @monitor.synchronize { @size.zero? }
      end

      def log(subsystem, level, message, facility_id: nil, **data)
        @monitor.synchronize do
          @seq_counter += 1
          uptime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time
          norm_sub = subsystem.to_sym
          norm_lvl = Rubik::Kernel.normalize_level(level)

          record = Record.new(
            seq: @seq_counter,
            uptime: uptime,
            subsystem: norm_sub,
            level: norm_lvl,
            facility_id: facility_id,
            message: message.to_s,
            data: data
          )

          @buffer[@head] = record
          @head = (@head + 1) % @capacity
          @size += 1 if @size < @capacity
          record
        end
      end

      def tail(limit = 50, level: nil, subsystem: nil, since_seq: nil)
        @monitor.synchronize do
          records = snapshot_unlocked
          records = filter_since(records, since_seq) if since_seq
          records = filter_subsystem(records, subsystem) if subsystem
          records = filter_level(records, level) if level
          limit ? records.last(limit.to_i) : records
        end
      end

      def to_a
        @monitor.synchronize { snapshot_unlocked }
      end

      def clear!
        @monitor.synchronize do
          @buffer.fill(nil)
          @head = 0
          @size = 0
          self
        end
      end

      def formatted(records = nil, color: false)
        recs = records || tail
        return "" if recs.empty?

        recs.map { |r| Rubik::Kernel.format_line(r, color: color) }.join("\n")
      end

      private

      def snapshot_unlocked
        return [] if @size.zero?

        start_idx = @size < @capacity ? 0 : @head
        Array.new(@size) { |i| @buffer[(start_idx + i) % @capacity] }
      end

      def filter_since(records, since_seq)
        seq_threshold = since_seq.to_i
        records.select { |r| r.seq > seq_threshold }
      end

      def filter_subsystem(records, subsystem)
        subs = Array(subsystem).flat_map { |s| s.to_s.split(",") }.map(&:strip).map(&:downcase)
        records.select { |r| subs.include?(r.subsystem.to_s.downcase) }
      end

      def filter_level(records, level)
        if level.is_a?(Integer)
          records.select { |r| SEVERITY_LEVELS.fetch(r.level, 7) <= level }
        else
          levels = Array(level).flat_map { |l| l.to_s.split(",") }.to_set { |l| Rubik::Kernel.normalize_level(l) }
          records.select { |r| levels.include?(r.level) }
        end
      end
    end
  end
end
