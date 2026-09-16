# frozen_string_literal: true

# One-off analysis of _report/unit_profile.csv: dedupe repeated measurements
# (profiler resume appends), report true serial total, and check whether
# SLOW_UNIT_FILES in the Rakefile still matches the >15s set.
# Usage: ruby dev/analyze_profile.rb

rows = File.readlines("_report/unit_profile.csv", chomp: true).map do |l|
  parts = l.split(",", 4)
  { t: parts[0].to_f, s: parts[1], f: parts[2] }
end

uniq = {}
rows.each { |r| uniq[r[:f]] = r } # last measurement wins

total = uniq.values.sum { |r| r[:t] }
puts format("unique=%<uniq>d rows=%<rows>d total_serial=%<total>.1fs (%<mins>.1f min) avg=%<avg>.1fs",
            uniq: uniq.size, rows: rows.size, total: total, mins: total / 60, avg: total / uniq.size)
counts = uniq.values.group_by { |r| r[:s] }.map { |k, v| "#{k}=#{v.size}" }
puts "status counts: #{counts.join(' ')}"

slow = uniq.values.select { |r| r[:t] > 15 }.map { |r| r[:f] }.sort
puts "--- measured >15s (#{slow.size})"
slow.each do |f|
  r = uniq[f]
  puts format("  %<t>7.2fs %<s>-8s %<f>s", t: r[:t], s: r[:s], f: f)
end

current = File.read("Rakefile")[/SLOW_UNIT_FILES = %w\[(.*?)\]/m, 1].split
stale = current - slow
missing = slow - current
puts "--- in Rakefile but NOT >15s now (#{stale.size}): #{stale.inspect}"
puts "--- >15s but NOT in Rakefile (#{missing.size}): #{missing.inspect}"

boot_est = 8.5 * uniq.size
puts format("--- boot estimate: %<boot>.0fs of serial total; test bodies ~%<bodies>.0fs",
            boot: boot_est, bodies: total - boot_est)
