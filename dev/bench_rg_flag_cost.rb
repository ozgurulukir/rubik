# frozen_string_literal: true

# Measures what each rg flag costs on a synthetic repo. Findings (5.000
# files, Plan 52 §9 D-2): `-j 1` triples scan time (247 → 864 ms) while the
# prune globs are free — that is why NativeSearch runs rg parallel.
# Usage: ruby dev/bench_rg_flag_cost.rb [count]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"
require "open3"
require "fileutils"
require "tmpdir"

count = (ARGV[0] || 2_000).to_i
root = File.join(Dir.tmpdir, "rubik_flag_cost_#{count}")
rg = Rubik::Tools::NativeSearch.available? ? Rubik::Tools::NativeSearch.rg_path : (puts "rg not installed" || exit)

puts "== generating #{count}-file synthetic repo =="
Rubik::Benchmark::SynthRepo.generate(root, count: count)

def best_of(argv, root)
  best = Float::INFINITY
  3.times do
    s = Benchmark.realtime do
      _o, _e, st = Open3.capture3(*argv, chdir: root)
      raise "rg exit #{st.exitstatus}" unless [0, 1].include?(st.exitstatus)
    end
    best = s if s < best
  end
  (best * 1000).round(1)
end

begin
  base = [rg, "--no-messages", "--no-heading", "-n", "--hidden", "-i", "-e", "needle_rare_marker", "."]
  globs = Rubik::Context::Scanner::DEFAULT_IGNORES.flat_map { |g| ["-g", "!#{g}"] }

  puts "parallel, no globs:  #{best_of(base, root)} ms"
  puts "j1, no globs:        #{best_of(base + %w[-j 1], root)} ms"
  puts "parallel + globs:    #{best_of(base + globs, root)} ms"
  puts "j1 + globs:          #{best_of(base + %w[-j 1] + globs, root)} ms"
ensure
  FileUtils.remove_entry(root)
end
