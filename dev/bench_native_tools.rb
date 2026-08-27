# frozen_string_literal: true

# Native tool baselines vs Ruby: ripgrep variants, ast-grep structural scan,
# fd listing and JSON library comparison. Each section degrades gracefully
# when the binary/gem is absent.
# Usage: ruby dev/bench_native_tools.rb [root_dir] [pattern]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"
require "open3"
require "json"

root = File.expand_path(ARGV[0] || File.expand_path("..", __dir__))
pattern = ARGV[1] || "initialize"

def ms(label, seconds, extra = "")
  puts format("%<label>-42s %9.1f ms  %<extra>s", label: label, seconds: seconds * 1000, extra: extra)
end

def bench(label, extra = "")
  best = Float::INFINITY
  3.times do
    s = Benchmark.realtime { yield }
    best = s if s < best
  end
  ms(label, best, extra)
rescue StandardError, Errno::ENOENT => e
  puts format("%<label>-42s %9s  %<extra>s", label: label, seconds: "skip", extra: e.message[0, 40])
end

which = defined?(TTY::Which) ? TTY::Which.method(:which) : nil
rg = which ? which.call("rg") : nil
sg = which ? which.call("sg") : nil
fd = which ? which.call("fd") : nil

bench("rg -n (ripgrep)") { Open3.capture3(rg, "-n", "--no-heading", "-e", pattern, ".", chdir: root) } if rg
bench("rg -l (files only)") { Open3.capture3(rg, "-l", "-e", pattern, ".", chdir: root) } if rg
bench("rg --json") { Open3.capture3(rg, "--json", "-e", pattern, ".", chdir: root) } if rg
bench("sg run structural (ast-grep)") { Open3.capture3(sg, "run", "-p", "def $F", "--json=compact", ".", chdir: root) } if sg
bench("fd -tf (listing)") { Open3.capture3(fd, "-t", "f", ".", chdir: root) } if fd

# JSON: stdlib is C-backed; oj must beat it broadly to justify a dependency.
require "tmpdir"
Dir.mktmpdir do |dir|
  data = { symbols: Array.new(7_000) do |i|
    { name: "sym_#{i}", file: "src/mod_#{i % 200}/f_#{i}.rb", line: i, signature: "def s#{i}(a, b)", calls: %w[foo bar] }
  end }
  json = JSON.generate(data)
  bench("JSON.generate 7k symbols") { JSON.generate(data) }
  bench("JSON.parse 7k symbols") { JSON.parse(json) }
  begin
    require "oj"
    bench("Oj.dump 7k symbols") { Oj.dump(data) }
    bench("Oj.load 7k symbols") { Oj.load(json) }
  rescue LoadError
    puts "(oj not installed — comparison skipped)"
  end
end
