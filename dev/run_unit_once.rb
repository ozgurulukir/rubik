# frozen_string_literal: true

# Loads unit test files into one process so a single Minitest run pays
# the boot cost once per run. Fast feedback loop; CI can run this via
# `rake test:unit_once`.
#
# Suite selection: `RUBIK_TEST_SUITE=fast` (excludes SLOW_UNIT_FILES) or
# `RUBIK_TEST_SUITE=slow` (only SLOW_UNIT_FILES).
#
# Slice support (opt-in pilot, `rake test:parallel`): `RUBIK_TEST_SLICE=i/N`
# runs only the files whose sorted index is congruent to i-1 (mod N). ARGV is
# left untouched so Minitest parses only its own options (passing `--slice`
# through ARGV made the child abort with "invalid option: --slice").

require_relative "slow_unit_files"

files = Dir["test/unit/**/test_*.rb"]
case ENV.fetch("RUBIK_TEST_SUITE", nil)
when "fast"
  files -= SLOW_UNIT_FILES
when "slow"
  files &= SLOW_UNIT_FILES
end

if (spec = ENV.fetch("RUBIK_TEST_SLICE", nil))
  abort "usage: RUBIK_TEST_SLICE=i/N" unless spec.match?(%r{\A\d+/\d+\z})
  i, n = spec.split("/").map { |s| Integer(s, 10) }
  abort "slice i must be in 1..N (got #{spec})" unless (1..n).cover?(i)
  files = files.select.with_index { |_, idx| idx % n == i - 1 }
end

files.each { |f| require_relative "../#{f}" }
