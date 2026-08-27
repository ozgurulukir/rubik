# frozen_string_literal: true

# Latency of the hot built-in tool paths against native baselines (rg, git).
# Usage: ruby dev/bench_context_scan.rb [root_dir]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"
require "open3"

root = ARGV[0] || File.expand_path("..", __dir__)
root = File.expand_path(root)

def ms(label, seconds, extra = "")
  puts format("%<label>-44s %<seconds>9.1f ms  %<extra>s", label: label, seconds: seconds * 1000, extra: extra)
end

idx = Rubik::Context::Index.new(root_dir: root, native: "off")
cold = Benchmark.realtime { idx.full_scan }
ms("Index#full_scan (walker, cold)", cold, "(#{idx.files.size} files)")

idx2 = Rubik::Context::Index.new(root_dir: root, native: "off")
idx2.full_scan
inc = Benchmark.realtime { idx2.incremental_scan }
ms("Index#incremental_scan", inc)

if Rubik::Context::GitLister.files(root)
  git_scan = Benchmark.realtime do
    Rubik::Context::Scanner.new(root_dir: root, native: "on").scan
  end
  ms("Scanner#scan (git ls-files)", git_scan, "ratio #{(cold / git_scan).round(2)}x vs cold")
else
  puts "(root is not a git repo — git fast path skipped)"
end

tool_off = Rubik::Tools::GrepSearchTool.new(nil, idx2, root_dir: root, config: Rubik::Benchmark::Runner::NativeConfig.new("off"))
t_ruby = Benchmark.realtime { tool_off.execute({ "query" => "def initialize", "max_results" => 50 }) }
ms("grep_search pure Ruby", t_ruby)

if Rubik::Tools::NativeSearch.available?
  tool_on = Rubik::Tools::GrepSearchTool.new(nil, idx2, root_dir: root, config: Rubik::Benchmark::Runner::NativeConfig.new("on"))
  t_native = Benchmark.realtime { tool_on.execute({ "query" => "def initialize", "max_results" => 50 }) }
  ms("grep_search rg offload", t_native, "ratio #{(t_ruby / t_native).round(2)}x")
else
  puts "(rg unavailable — native grep skipped)"
end

t_git = Benchmark.realtime do
  out, = Open3.capture2("git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard")
  out
end
ms("git ls-files baseline", t_git)
