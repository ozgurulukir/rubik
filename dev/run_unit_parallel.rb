# frozen_string_literal: true

# Opt-in process-parallel runner for unit tests.
#
# Spawns N ruby workers via Process.spawn; each runs Minitest over a
# deterministic round-robin slice of the sorted unit file list. Worker output
# is streamed live (out/err to $stdout) so failures stay visible.
#
# Suite selection: respects `RUBIK_TEST_SUITE=fast` or `RUBIK_TEST_SUITE=slow`.
# Coverage: if `RUBIK_COVERAGE=1`, partitions `RUBIK_COVERAGE_SUITE` per worker
# so SimpleCov results merge cleanly without overwriting.
#
# Usage: bundle exec rake test:parallel           # 4 workers (all unit files)
#        bundle exec rake test:parallel:fast      # 4 workers (fast unit files)
#        bundle exec rake test:parallel:fast[2]   # 2 workers (CI or low-core)

require "rbconfig"
require_relative "../lib/rubik"
require_relative "slow_unit_files"

def spawn_worker(worker_count, worker_index)
  suite = ENV.fetch("RUBIK_TEST_SUITE", nil)
  env = {
    "RUBIK_TEST_SLICE" => "#{worker_index}/#{worker_count}",
    "RUBYOPT" => "-rbundler/setup #{ENV.fetch('RUBYOPT', nil)}".strip
  }
  env["RUBIK_TEST_SUITE"] = suite if suite
  if ENV["RUBIK_COVERAGE"] == "1"
    base_suite = ENV.fetch("RUBIK_COVERAGE_SUITE", suite || "unit")
    env["RUBIK_COVERAGE_SUITE"] = "#{base_suite}-worker-#{worker_index}"
  end

  Process.spawn(
    env,
    RbConfig.ruby, "-Ilib", "-Itest",
    File.expand_path("run_unit_once.rb", __dir__),
    [:out, :err] => $stdout
  )
end

n = (ARGV[0] || 4).to_i
abort "worker count must be greater or equal 1 (got #{ARGV[0].inspect})" unless n >= 1

files = Dir["test/unit/**/test_*.rb"]
suite = ENV.fetch("RUBIK_TEST_SUITE", nil)
case suite
when "fast"
  files -= SLOW_UNIT_FILES
when "slow"
  files &= SLOW_UNIT_FILES
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pids = (1..n).map { |i| spawn_worker(n, i) }
puts "test:parallel: #{n} workers over #{files.size} files (#{suite || 'all'})"
$stdout.flush

# LIFO-ordered reversion: every spawned process gets exactly one registered
# inverse; on interrupt/timeout the list unwinds newest-first via kill_tree.
inverses = pids.map { |pid| -> { Rubik::Platform.kill_tree(pid) } }

exit_codes = pids.map do |pid|
  _pid2, status = Process.wait2(pid)
  inverses.pop
  status.exitstatus
rescue StandardError
  inverses.pop&.call
  -1
end
wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

puts format("test:parallel wall: %<wall>.1fs (exit codes: %<codes>s)", wall: wall, codes: exit_codes.inspect)
$stdout.flush
failed = exit_codes.any? { |c| !c.zero? }
exit(failed ? 1 : 0)
