# frozen_string_literal: true

# Lifecycle soak auditor (G26) — the automated AGENTS.md §6 checklist:
# drive Context / ComponentFiber through N lifecycle epochs and audit that
# the Omega accumulator returns to its baseline after every family, with
# every inverse executed exactly once per epoch (no orphaned cleanups, no
# double-runs, no dead inverses left behind). Deliberately a standalone
# probe, not a runtime subsystem (see _plan/lifecycle-auditor-g26-2026-09-30.md).
# The suite-embedded small-N guard is test/unit/test_runtime_zero_restart_soak.rb.
#
# Usage: ruby dev/soak_lifecycle.rb [epochs=1000]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"

epochs = (ARGV[0] || 1000).to_i
abort "usage: ruby dev/soak_lifecycle.rb [epochs]" if epochs < 1

# Family 1 — context epochs: extend, register, provide, dispose. The cascade
# inverse must prune back out of the parent accumulator every epoch, and the
# child's own inverse must run exactly once (never skipped, never doubled).
def check_context_epochs(epochs)
  parent = Rubik::Runtime::Context.new
  ran = 0
  epochs.times do
    child = parent.extend
    child.on_dispose { ran += 1 }
    child.provide("db", Object.new)
    child.dispose
  end
  violations = []
  violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
  violations << "inverse runs #{ran}, expected #{epochs}" unless ran == epochs
  violations
end

# Family 2 — service epochs: re-providing a live key must swap the value
# without stacking a second delete-inverse (zero-restart rule); unprovide
# must retract service AND inverse symmetrically; unproviding an unknown
# key is a no-op.
def check_service_epochs(epochs)
  ctx = Rubik::Runtime::Context.new
  epochs.times do |i|
    key = "svc_#{i % 5}"
    ctx.provide(key, Object.new)
    ctx.provide(key, Object.new) # swap — must never stack
  end
  violations = []
  live = [epochs, 5].min
  violations << "omega after swap epochs = #{ctx.disposable_count}, expected #{live}" unless ctx.disposable_count == live

  epochs.times { |i| ctx.unprovide("svc_#{i % 5}") }
  violations << "omega after unprovides = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
  violations << "services not empty: #{ctx.service_names.inspect}" unless ctx.services.empty?
  violations
end

# Family 3 — fiber activation cycles: each activate! opens a scoped
# sub-context, each deactivate! disposes it. After N cycles the fiber is
# Pending again with no instance and the parent accumulator is flat.
def check_fiber_cycles(epochs)
  parent = Rubik::Runtime::Context.new
  ran = 0
  fiber = Rubik::Runtime::ComponentFiber.new(name: "soak") do |sub|
    sub.on_dispose { ran += 1 }
    :ok
  end
  epochs.times do
    unless fiber.activate!(parent)
      return ["activate! returned false for fiber '#{fiber.name}' (#{fiber.last_error})"]
    end
    fiber.deactivate!
  end
  violations = []
  violations << "state #{fiber.state}, expected pending" unless fiber.state == :pending
  violations << "instance not released" unless fiber.instance.nil?
  violations << "sub_context not released" unless fiber.sub_context.nil?
  violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
  violations << "inverse runs #{ran}, expected #{epochs}" unless ran == epochs
  violations
end

# Family 4 — rollback cycles: a factory that registers an inverse and then
# raises must trigger the atomic rollback every epoch — activate! false,
# state failed, the partial inverse already run, parent accumulator flat.
def check_rollback_cycles(epochs)
  parent = Rubik::Runtime::Context.new
  rolled = 0
  boom = Rubik::Runtime::ComponentFiber.new(name: "boom") do |sub|
    sub.on_dispose { rolled += 1 }
    raise "factory failure"
  end
  epochs.times do
    return ["activate! returned true despite a failing factory"] if boom.activate!(parent)
  end
  violations = []
  violations << "state #{boom.state}, expected failed" unless boom.state == :failed
  violations << "last_error not recorded" unless boom.last_error
  violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
  violations << "rollback runs #{rolled}, expected #{epochs}" unless rolled == epochs
  violations
end

families = [
  ["context epochs", method(:check_context_epochs)],
  ["service epochs", method(:check_service_epochs)],
  ["fiber cycles", method(:check_fiber_cycles)],
  ["rollback cycles", method(:check_rollback_cycles)]
]

puts "== lifecycle soak: #{epochs} epochs/family =="
results = families.map do |name, probe|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  violations = begin
    probe.call(epochs)
  rescue StandardError => e
    ["#{e.class}: #{e.message}"]
  end
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  ok = violations.empty?
  puts format("%-16s %s  %8.1fms", name, ok ? "PASS" : "FAIL", dt * 1000)
  violations.each { |v| puts "  ! #{v}" }
  [name, ok]
end

passed = results.count { |_, ok| ok }
puts "--"
puts "#{passed}/#{results.size} families clean"
exit(passed == results.size ? 0 : 1)
