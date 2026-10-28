# frozen_string_literal: true

require "benchmark"
require "monitor"
require_relative "../lib/rubik"

module BenchmarkHelpers
  class BenchmarkInstance
    attr_reader :id, :parent_id

    def initialize(id)
      @id = id
      @parent_id = "root"
      @active = true
      @monitor = Monitor.new
    end

    def active?
      @monitor.synchronize { @active }
    end

    def error_paused? = false
    def awaiting_human? = false
    def awaiting_budget? = false

    def complete!
      @monitor.synchronize { @active = false }
    end

    def to_h = { id: @id, state: @active ? "running" : "completed" }
  end

  # Sleep Polling implementation
  class PollingSupervisor
    include Rubik::Orchestrator::Subagent::WaitSupervisor

    attr_reader :instances

    def initialize
      @instances = {}
      @monitor = Monitor.new
    end

    def deferred_pending?(_ids) = false
    def queued_spec(_id) = nil
  end

  # CondVar Reactive implementation
  class CondVarSupervisor
    attr_reader :instances

    def initialize
      @instances = {}
      @monitor = Monitor.new
      @wait_cond = @monitor.new_cond
    end

    def notify_wait!
      @monitor.synchronize { @wait_cond&.broadcast }
    end

    def wait(ids = nil, timeout: 5, wait_for_budget: true)
      target_ids = Array(ids).compact.map(&:to_s)
      deadline = Time.now + [timeout.to_i, 1].max

      @monitor.synchronize do
        loop do
          candidates = target_ids.empty? ? @instances.values : target_ids.filter_map { |id| @instances[id] }
          active_targets = candidates.select do |inst|
            inst.active? && !inst.error_paused? && !inst.awaiting_human? && (!wait_for_budget || !inst.awaiting_budget?)
          end

          rem = deadline - Time.now
          break if (active_targets.empty? && !deferred_pending?(target_ids)) || rem <= 0

          @wait_cond.wait([rem, 0].max)
        end

        candidates = target_ids.empty? ? @instances.values : target_ids.filter_map { |id| @instances[id] || queued_spec(id) }
        paused = candidates.select { |c| parked_candidate?(c) }
        active = candidates.select { |c| c.respond_to?(:active?) && c.active? }
        Rubik::Orchestrator::Subagent::WaitSupervisor::WaitOutcome.new(
          reason: :settled,
          rows: candidates.map(&:to_h),
          paused: paused.map(&:id),
          active: active.map(&:id)
        )
      end
    end

    def parked_candidate?(_candidate) = false
    def deferred_pending?(_ids) = false
    def queued_spec(_id) = nil

    def complete_subagent(id)
      inst = @instances[id]
      inst&.complete!
      notify_wait!
    end
  end
end

n = 50
p_durations = []
n.times do
  sup = BenchmarkHelpers::PollingSupervisor.new
  inst = BenchmarkHelpers::BenchmarkInstance.new("sub-1")
  sup.instances["sub-1"] = inst

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t = Thread.new do
    sleep 0.01
    inst.complete!
  end

  sup.wait(["sub-1"], timeout: 5)
  t.join
  p_durations << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
end

c_durations = []
n.times do
  sup = BenchmarkHelpers::CondVarSupervisor.new
  inst = BenchmarkHelpers::BenchmarkInstance.new("sub-1")
  sup.instances["sub-1"] = inst

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t = Thread.new do
    sleep 0.01
    sup.complete_subagent("sub-1")
  end

  sup.wait(["sub-1"], timeout: 5)
  t.join
  c_durations << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
end

p_avg = (p_durations.sum / n) * 1000
c_avg = (c_durations.sum / n) * 1000
speedup = p_avg / c_avg

puts "Polling wait time average: #{p_avg.round(3)} ms"
puts "CondVar wait time average: #{c_avg.round(3)} ms"
puts "Speedup factor: #{speedup.round(2)}x"
