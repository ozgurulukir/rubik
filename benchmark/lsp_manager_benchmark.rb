# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik/lsp/manager"
require "benchmark"

class DummyClient
  attr_reader :running, :all_diagnostics, :all_diagnostic_snapshots

  def initialize(running:, diagnostics:, snapshots:)
    @running = running
    @all_diagnostics = diagnostics
    @all_diagnostic_snapshots = snapshots
  end
end

manager = Rubik::LSP::Manager.new(config: { "lsp.enabled" => true })

20.times do |i|
  diags = (1..50).to_h { |j| ["/path/to/file_#{i}_#{j}.rb", [{ line: 1, message: "Error" }]] }
  snaps = (1..50).to_h { |j| ["/path/to/file_#{i}_#{j}.rb", { state: :fresh, diagnostics: [], document_version: 1, published_version: 1 }] }
  client = DummyClient.new(running: true, diagnostics: diags, snapshots: snaps)
  manager.clients["lang_#{i}"] = client
end

10.times do |i|
  client = DummyClient.new(running: false, diagnostics: {}, snapshots: {})
  manager.clients["inactive_#{i}"] = client
end

# Warmup
100.times do
  manager.all_diagnostic_snapshots
  manager.all_diagnostics
end

iterations = 100_000

GC.start
gc_before = GC.stat(:total_allocated_objects)
time_snaps = Benchmark.realtime do
  iterations.times do
    manager.all_diagnostic_snapshots
  end
end
gc_after = GC.stat(:total_allocated_objects)

puts "all_diagnostic_snapshots (#{iterations} iterations):"
puts "  Time: #{format('%.4f', time_snaps)}s"
puts "  Allocated objects: #{gc_after - gc_before}"

GC.start
gc_before = GC.stat(:total_allocated_objects)
time_diags = Benchmark.realtime do
  iterations.times do
    manager.all_diagnostics
  end
end
gc_after = GC.stat(:total_allocated_objects)

puts "all_diagnostics (#{iterations} iterations):"
puts "  Time: #{format('%.4f', time_diags)}s"
puts "  Allocated objects: #{gc_after - gc_before}"
