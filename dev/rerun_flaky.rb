# frozen_string_literal: true

# Flaky-test probe (G18): run one test file N times in fresh processes and
# report pass/fail counts plus wall-time spread. A file that ever fails here
# gets test:profile-d and either fixed at the race site or quarantined in
# SLOW_UNIT_FILES (see TESTING.md policy) — never retried inside assertions.
#
# Usage: ruby dev/rerun_flaky.rb test/unit/test_x.rb [times=5]

file = ARGV[0]
times = (ARGV[1] || 5).to_i
abort "usage: ruby dev/rerun_flaky.rb <test_file> [times]" unless file && File.exist?(file)
abort "times must be >= 1" if times < 1

results = []
times.times do |i|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = system(RbConfig.ruby, "-Ilib", "-Itest", file)
  dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  results << { run: i + 1, ok: ok, seconds: dt }
  puts format("run %2d  %s  %5.1fs", i + 1, ok ? "PASS" : "FAIL", dt)
  $stdout.flush
end

passes = results.count { |r| r[:ok] }
times_list = results.map { |r| r[:seconds] }
puts "--"
puts "#{passes}/#{results.size} passed; wall min/avg/max = " \
     "#{format('%.1f', times_list.min)}/#{format('%.1f', times_list.sum / times_list.size)}/#{format('%.1f', times_list.max)}s"
exit(passes == results.size ? 0 : 1)
