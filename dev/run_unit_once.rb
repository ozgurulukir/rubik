# frozen_string_literal: true

# Loads every unit test file into one process so a single Minitest run pays
# the ~8.5s boot cost once per run. Fast feedback loop; CI can run this via
# `rake test:unit_once`.
#
# Slice support (opt-in pilot, `rake test:parallel`): `RUBIK_TEST_SLICE=i/N`
# runs only the files whose sorted index is congruent to i-1 (mod N). ARGV is
# left untouched so Minitest parses only its own options (passing `--slice`
# through ARGV made the child abort with "invalid option: --slice").
files = Dir["test/unit/**/test_*.rb"]
if (spec = ENV.fetch("RUBIK_TEST_SLICE", nil))
  abort "usage: RUBIK_TEST_SLICE=i/N" unless spec.match?(%r{\A\d+/\d+\z})
  i, n = spec.split("/").map { |s| Integer(s, 10) }
  abort "slice i must be in 1..N (got #{spec})" unless (1..n).cover?(i)
  files = files.select.with_index { |_, idx| idx % n == i - 1 }
end
files.each { |f| require_relative "../#{f}" }
