# frozen_string_literal: true

# R6 (review 2026-09-17): the README test badge was hand-edited and drifted
# (stated 1327 while the suite was 1544). This script is the generator: run
# the full suite (unit via dev/run_unit_once.rb + integration), parse the
# real Minitest summaries, and rewrite the README badge line.
#
#   rake test:badge
#
# Refuses to touch the README unless every run reports 0 failures / 0 errors,
# so the badge can never advertise a red suite.

require "open3"
require "rbconfig"

README = "README.md"
BADGE_RE = %r{\[!\[Test Suite\]\(https://img\.shields\.io/badge/tests-[^)]+\)\]\(\)}

def parse_summary(label, stdout_and_stderr)
  summary_line = stdout_and_stderr.lines.grep(/\d+ runs?, \d+ assertions?, \d+ failures?, \d+ errors?/).last
  abort("[test:badge] no Minitest summary found in #{label} output") unless summary_line

  m = summary_line.match(/(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?/)
  runs, assertions, failures, errors = m.captures.map { |c| Integer(c, 10) }
  abort("[test:badge] #{label} is red (#{failures} failures / #{errors} errors) — badge NOT updated") unless failures.zero? && errors.zero?

  [runs, assertions]
end

puts "==> unit suite (dev/run_unit_once.rb)..."
unit_out, unit_status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-Itest", "dev/run_unit_once.rb")
unit_runs, unit_assertions = parse_summary("unit", unit_out)
abort("[test:badge] unit runner exited #{unit_status.exitstatus}") unless unit_status.success?
puts "    #{unit_runs} runs / #{unit_assertions} assertions"

puts "==> integration suite (3 files, one process)..."
integration_loader = 'Dir["test/integration/**/test_*.rb"].each { |f| require File.expand_path(f) }'
int_out, int_status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-Itest", "-e", integration_loader)
int_runs, int_assertions = parse_summary("integration", int_out)
abort("[test:badge] integration runner exited #{int_status.exitstatus}") unless int_status.success?
puts "    #{int_runs} runs / #{int_assertions} assertions"

total_runs = unit_runs + int_runs
total_assertions = unit_assertions + int_assertions
badge = "[![Test Suite](https://img.shields.io/badge/tests-#{total_runs}%20runs%20%7C%20100%25%20passed-brightgreen.svg)]()"

readme = File.read(README)
unless BADGE_RE.match?(readme)
  abort("[test:badge] README badge line not found (pattern #{BADGE_RE}) — nothing updated")
end

updated = readme.sub(BADGE_RE) { badge }
if updated == readme
  puts "[test:badge] badge already up to date (#{total_runs} runs) — no change"
else
  File.write(README, updated)
  puts "[test:badge] README badge updated: #{total_runs} runs | #{total_assertions} assertions | 100% passed"
end
