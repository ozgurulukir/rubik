# frozen_string_literal: true

# Plan 52 §8 measurement harness: latency of the hot built-in tool paths on a
# synthetic repo, plus native-vs-Ruby ratios. Run from the repo root:
#
#   ruby benchmark/tool_latency.rb           # 5.000-file synthetic repo
#   ruby benchmark/tool_latency.rb 500       # smaller/faster profile
#
# Absolute numbers are hardware-specific; the acceptance criteria are the
# RATIO lines (Plan 52 §8) and the `!benchmark` runner (ratio-based targets).

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"
require "fileutils"

count = (ARGV[0] || 5000).to_i
repo = File.join(Dir.tmpdir, "rubik_tool_latency_#{count}")
puts "== Generating #{count}-file synthetic repo at #{repo} =="
Rubik::Benchmark::SynthRepo.generate(repo, count: count)

def ms(label, seconds, extra = "")
  puts format("%<label>-46s %<seconds>9.1f ms  %<extra>s", label: label, seconds: seconds * 1000, extra: extra)
end

def best_of(runs, &probe)
  Array.new(runs) { probe.call }.min
end

def grep_once(repo, native)
  idx = Rubik::Context::Index.new(root_dir: repo, native: native)
  tool = Rubik::Tools::GrepSearchTool.new(nil, idx, root_dir: repo, config: Rubik::Benchmark::Runner::NativeConfig.new(native))
  Benchmark.realtime { tool.execute({ "query" => "needle_rare_marker", "max_results" => 50 }) }
end

begin
  puts "== Context scan =="
  walker_time = best_of(3) do
    scanner = Rubik::Context::Scanner.new(root_dir: repo, native: "off")
    Benchmark.realtime { @files = scanner.scan }
  end
  ms("Scanner walk (native: off)", walker_time, "(#{@files.size} files)")

  if Rubik::Context::GitLister.files(repo)
    git_time = best_of(3) do
      scanner = Rubik::Context::Scanner.new(root_dir: repo, native: "on")
      Benchmark.realtime { scanner.scan }
    end
    ms("Scanner git ls-files (native: on)", git_time, "ratio #{(walker_time / git_time).round(2)}x")
  else
    puts "(git unavailable — fast path skipped)"
  end

  puts "== grep_search (nadir pattern, cap 50) =="
  rg_ok = Rubik::Tools::NativeSearch.available?
  native_time = rg_ok ? best_of(3) { grep_once(repo, "on") } : nil
  fallback_time = best_of(3) { grep_once(repo, "off") }
  ms("grep pure Ruby (tools.native: off)", fallback_time)
  if native_time
    ms("grep rg offload  (tools.native: on)", native_time, "ratio #{(fallback_time / native_time).round(2)}x")
  else
    puts "(rg unavailable — native path skipped)"
  end

  puts "== AST warm (all supported files) =="
  graph = Rubik::AST::Graph.new
  supported = Rubik::AST::Extractor.supported_extensions
  ast_time = Benchmark.realtime do
    @files.each_key do |rel|
      ext = File.extname(rel).downcase
      graph.index_file(File.join(repo, rel)) if supported.include?(ext)
    end
  end
  ms("AST index", ast_time, "(#{graph.symbols.size} symbols)")
ensure
  FileUtils.remove_entry(repo)
end
