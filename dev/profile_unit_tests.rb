# frozen_string_literal: true

# Per-file unit test profiler with resume support.
#
# Each test file runs in its own ruby process (like CI would); wall time is
# recorded. Results append to _report/unit_profile.csv (gitignored) so a
# timed-out probe can resume where it left off.
#
# Usage: ruby -Ilib -Itest dev/profile_unit_tests.rb [timeout_per_file=45]
require "rbconfig"
require "english"
require "fileutils"

OUT_DIR = "_report"
OUT = File.join(OUT_DIR, "unit_profile.csv")
PER_FILE = (ARGV[0] || 45).to_f

FileUtils.mkdir_p(OUT_DIR)
done = {}
if File.exist?(OUT)
  rows = File.readlines(OUT, chomp: true)
             .map { |l| l.split(",", 4) } # time,status,path,summary
             .select { |p| p.size >= 3 && !p[2].nil? }
  # Resume appends produced duplicate rows for the same file (400 rows for
  # 180 files), inflating serial totals. Compact to the last measurement
  # per path so the CSV stays truthful for future analysis.
  latest = {}
  rows.each { |p| latest[p[2]] = p }
  if latest.size < rows.size
    File.write(OUT, +"")
    latest.each_value do |p|
      File.write(OUT, "#{p.join(',')}\n", mode: "a")
    end
    puts "compacted #{rows.size} rows -> #{latest.size} (duplicate measurements dropped)"
  end
  latest.each_key { |f| done[f] = true }
end

files = Dir["test/unit/**/test_*.rb"]
todo = files.reject { |f| done.key?(f) }
puts "files=#{files.size} already=#{done.size} todo=#{todo.size} timeout=#{PER_FILE}s"
$stdout.flush

# Runs one file in a child process; returns [exit_code, output, timed_out?]
def run_file(file, timeout)
  rd, wr = IO.pipe
  rd.binmode
  pid = Process.spawn(RbConfig.ruby, "-Ilib", "-Itest", file, [:out, :err] => wr)
  wr.close
  killer = Thread.new do
    sleep timeout
    begin
      Process.kill("KILL", pid)
    rescue StandardError
      nil
    end
  end
  output = rd.read.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  Process.wait(pid)
  killer.kill
  code = $CHILD_STATUS.exitstatus
  timed_out = code.nil? || code == 137 || code == 1_024 # KILL on posix/win
  [code, output, timed_out]
rescue StandardError => e
  [-1, "PROBE_ERROR: #{e.class}: #{e.message}", false]
ensure
  rd&.close
end

todo.each do |file|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  code, output, timed_out = run_file(file, PER_FILE)
  wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  summary = (output[/\d+ runs?, .* assertions, .*/] || "").lines.first.to_s.strip
  runs = output[/(\d+) runs?,/, 1]
  fails = output[/, (\d+) failures/, 1].to_i
  errs = output[/, (\d+) errors/, 1].to_i
  loads_err = output.include?("LoadError") || output.include?("SyntaxError")

  status =
    if timed_out then "TIMEOUT"
    elsif code == -1 then "PROBE_ERROR"
    elsif loads_err && runs.nil? then "LOAD_ERROR"
    elsif fails.positive? || errs.positive? then "FAIL"
    else "OK"
    end

  csv_line = "#{format('%.2f', wall)},#{status},#{file},#{summary.gsub(',', ';')}"
  File.open(OUT, "a") do |f|
    f.puts csv_line
  end
  puts format("%<wall>7.2fs %-<status>10s %<file>s", wall: wall, status: status, file: file)
  $stdout.flush
end

# Final report: top 25 slowest
lines = File.readlines(OUT, chomp: true).map { |l| l.split(",", 3) }
puts
puts "=== SLOWEST 25 ==="
lines.sort_by { |p| -p[0].to_f }.first(25).each do |p|
  puts format("%<wall>7.2fs %-<status>10s %<path>s", wall: p[0].to_f, status: p[1], path: p[2])
end
total = lines.sum { |p| p[0].to_f }
puts "TOTAL serial wall: #{format('%.1f', total)}s across #{lines.size} files"
