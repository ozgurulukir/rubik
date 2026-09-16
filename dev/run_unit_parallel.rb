# frozen_string_literal: true

# Opt-in process-parallel pilot for unit tests (see
# _plan/varsayilan-test-taski-ve-paralel-strateji-2026-09-14.md, Paket B).
#
# Spawns N ruby workers via Process.spawn; each runs Minitest over a
# deterministic round-robin slice of the sorted unit file list. Worker output
# is streamed live (out/err to $stdout) so failures stay visible.
#
# Slice handoff is via ENV (`RUBIK_TEST_SLICE=i/N`): ARGV passthrough made the
# child's Minitest abort with "invalid option: --slice".
#
# No shared artifact directory is needed: unit tests write only under
# Dir.mktmpdir / per-test temp homes (grep-verified over test/), so parallel
# workers do not collide on files.
#
# Usage: bundle exec rake test:parallel        # 4 workers (measured 0-failure default)
#        bundle exec rake test:parallel[8]     # 8 workers (faster; timing-fragile)
#        ruby -Ilib -Itest dev/run_unit_parallel.rb 4
#
# Acceptance (plan Paket B): at least 30% faster than `rake test:unit_once`;
# otherwise the pilot is deleted and the mechanism recorded as RED with the
# measurement.

require "rbconfig"
require_relative "../lib/rubik"

# --- Spawns one worker for slice worker_index/worker_count; returns its pid.
def spawn_worker(worker_count, worker_index)
  env = {
    "RUBIK_TEST_SLICE" => "#{worker_index}/#{worker_count}",
    # Child must see the locked gems (minitest 5.26), not the default gem
    # (minitest 6): bundler/setup inheritance instead of spawning bundle.bat.
    "RUBYOPT" => "-rbundler/setup #{ENV.fetch('RUBYOPT', nil)}".strip
  }
  Process.spawn(
    env,
    RbConfig.ruby, "-Ilib", "-Itest",
    File.expand_path("run_unit_once.rb", __dir__),
    [:out, :err] => $stdout
  )
end

n = (ARGV[0] || 8).to_i
abort "worker count must be greater or equal 1 (got #{ARGV[0].inspect})" unless n >= 1

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pids = (1..n).map { |i| spawn_worker(n, i) }
puts "test:parallel: #{n} workers over #{Dir['test/unit/**/test_*.rb'].size} files"
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
