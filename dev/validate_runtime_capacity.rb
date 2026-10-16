# frozen_string_literal: true

# Single documented command to reproduce runtime validation:
# - Lifecycle & Soak (1000 epochs across 11 families: context, fiber, plugin, MCP)
# - Quiet Concurrency Scheduler capacity (100 and 1000 requests, latency, timeout)
# - AST Persistent Cache cold vs warm sizing
# - Resource telemetry (threads, FDs, RSS, child processes)
#
# Usage:
#   bundle exec ruby dev/validate_runtime_capacity.rb [epochs=1000] [--quick] [--artifact PATH]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "time"
require "fileutils"

require_relative "runtime_validation/telemetry"
require_relative "runtime_validation/assessment"
require_relative "runtime_validation/soak_harness"
require_relative "runtime_validation/scheduler_harness"
require_relative "runtime_validation/cache_harness"
require_relative "runtime_validation/report_formatter"

epochs = 1000
quick = false
artifact_path = nil
seed = Random.new_seed

require "optparse"
OptionParser.new do |opts|
  opts.on("--epochs=N", Integer) { |value| epochs = value }
  opts.on("--quick") do
    quick = true
    epochs = 50
  end
  opts.on("--artifact=PATH") { |value| artifact_path = value }
  opts.on("--seed=N", Integer) { |value| seed = value }
end.parse!
epochs = Integer(ARGV.shift) unless ARGV.empty?
abort "epochs must be positive, with no extra arguments" unless epochs.positive? && ARGV.empty?

srand(seed)

date_str = Time.now.strftime("%Y-%m-%d")
artifact_path ||= File.expand_path("../_report/runtime-capacity-validation-#{date_str}.md", __dir__)

puts "=================================================================="
puts "  Rubik Runtime Capacity & Soak Validation Harness"
puts "  Epochs: #{epochs} | Seed: #{seed} | Quick: #{quick}"
puts "=================================================================="

t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# 1. Baseline Telemetry
puts "\n[1/4] Recording initial resource baseline..."
baseline = Rubik::RuntimeValidation::Telemetry.snapshot
sys_info = Rubik::RuntimeValidation::Telemetry.system_info

# 2. Lifecycle & Soak Families
puts "\n[2/4] Executing Lifecycle & Soak Families (#{epochs} epochs)..."
soak_harness = Rubik::RuntimeValidation::SoakHarness.new(epochs: epochs)
soak_results = soak_harness.run_all

soak_results.each do |r|
  status = if r[:inconclusive]
             "INCONCLUSIVE"
           else
             (r[:passed] ? "PASS" : "FAIL")
           end
  puts "  #{r[:name].to_s.ljust(28)} [#{status}]  #{r[:duration_ms].to_s.rjust(7)}ms"
  r[:violations].each { |v| puts "    ! #{v}" }
end

# 3. Quiet Concurrency Scheduler Benchmarks
puts "\n[3/4] Benchmarking Quiet Concurrency Scheduler..."
scheduler_harness = Rubik::RuntimeValidation::SchedulerHarness.new
sched_results = scheduler_harness.run_all

if sched_results[:requests100][:inconclusive]
  puts "  Scheduler benchmarks: SKIPPED (#{sched_results[:requests100][:reason]})"
else
  r100 = sched_results[:requests100]
  r1000 = sched_results[:requests1000]
  comp = sched_results[:scheduler_comparison]
  to = sched_results[:timeout_cancel]

  puts "  100 requests:  #{r100[:duration_s]}s (#{r100[:throughput_rps]} rps, p50=#{r100[:p50_ms]}ms, p95=#{r100[:p95_ms]}ms)"
  puts "  1000 requests: #{r1000[:duration_s]}s (#{r1000[:throughput_rps]} rps, p50=#{r1000[:p50_ms]}ms, p95=#{r1000[:p95_ms]}ms)"
  puts "  Timeout/Cancel: #{to[:elapsed_s]}s (clean abort, deadline 0.1s)"
  puts "  Speedup vs Sequential: #{comp[:speedup_ratio]}x faster"
end

# 4. AST Persistent Cache Benchmarks
puts "\n[4/4] Benchmarking AST Persistent Cache..."
cache_harness = Rubik::RuntimeValidation::CacheHarness.new
cache_results = cache_harness.run(quick ? 30 : 150)
puts "  Fixture: #{cache_results[:file_count]} files (#{cache_results[:total_source_bytes]} bytes)"
puts "  Cold Scan: #{cache_results[:cold_duration_ms]}ms | Cache Size: #{cache_results[:cache_size_bytes]} bytes"
puts "  Warm Load: #{cache_results[:warm_duration_ms]}ms | Speedup: #{cache_results[:speedup_ratio]}x faster"

# Post-Run Telemetry & GC
final_telemetry = Rubik::RuntimeValidation::Telemetry.snapshot
t_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total_duration_s = (t_end - t_start).round(2)

resource_checks = Rubik::RuntimeValidation::Assessment.resource_checks(baseline, final_telemetry)
checks = soak_results.map { |r| r[:inconclusive] ? nil : r[:passed] }
checks.concat(resource_checks.values)
checks.concat([:requests100, :requests1000].map do |key|
  Rubik::RuntimeValidation::Assessment.requests_passed?(sched_results[key])
end)
checks.concat([:timeout_cancel, :scheduler_comparison].map do |key|
  sched_results[key][:inconclusive] ? nil : sched_results[key][:passed]
end)
checks << cache_results[:passed]
verdict = Rubik::RuntimeValidation::Assessment.verdict(checks)
overall_passed = verdict == "PASS"

# Compile Data & Format Report
report_data = {
  timestamp: Time.now.utc.iso8601,
  seed: seed,
  epochs: epochs,
  total_duration_s: total_duration_s,
  passed: overall_passed,
  verdict: verdict,
  resource_checks: resource_checks,
  system_info: sys_info,
  telemetry: {
    baseline: baseline,
    final: final_telemetry
  },
  soak_results: soak_results,
  scheduler_results: sched_results,
  cache_results: cache_results
}

markdown_report = Rubik::RuntimeValidation::Telemetry.anonymize_path(
  Rubik::RuntimeValidation::ReportFormatter.format(report_data)
)
FileUtils.mkdir_p(File.dirname(artifact_path))
File.write(artifact_path, markdown_report)

puts "\n=================================================================="
puts "  Artifact generated: #{Rubik::RuntimeValidation::Telemetry.anonymize_path(artifact_path)}"
puts "  Overall Result: #{verdict}"
puts "=================================================================="

exit(if verdict == "PASS"
       0
     else
       (verdict == "INCONCLUSIVE" ? 2 : 1)
     end)
