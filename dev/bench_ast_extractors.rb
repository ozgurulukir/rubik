# frozen_string_literal: true

# Cost decomposition for the AST warm-up: stat/read/hash split, per-language
# extractor timing, body-access cost and the threaded-IO experiment that
# proved Windows/GVL gives no speedup (Plan 52 §2.3).
# Usage: ruby dev/bench_ast_extractors.rb [root_dir]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"
require "digest"

root = ARGV[0] || File.expand_path("..", __dir__)
scanner = Rubik::Context::Scanner.new(root_dir: File.expand_path(root), native: "off")
files = scanner.scan
supported = Rubik::AST::Extractor.supported_extensions
targets = files.keys.select { |k| supported.include?(File.extname(k).downcase) }
puts "== #{targets.size} supported files under #{root} =="

t = Benchmark.realtime do
  targets.each { |rel| Digest::SHA256.hexdigest(File.read(File.join(root, rel))) }
end
puts format("read + SHA-256        %8.1f ms total", t * 1000)

per_ext = Hash.new { |h, k| h[k] = [] }
targets.each do |rel|
  content = File.read(File.join(root, rel))
  t_ext = Benchmark.realtime { Rubik::AST::Extractor.extract(File.join(root, rel), content) }
  per_ext[File.extname(rel)] << t_ext
end

per_ext.sort_by { |_, v| -v.sum }.each do |ext, times|
  avg = times.sum / times.size * 1000
  puts format("extract %-4s           %8.2f ms/file  x%d files", ext, avg, times.size)
end

graph = Rubik::AST::Graph.new
t_all = Benchmark.realtime do
  targets.each { |rel| graph.index_file(File.join(root, rel)) }
end
puts format("AST index (lazy body) %8.1f ms total  (%d symbols)", t_all * 1000, graph.symbols.size)

[4, 8].each do |n|
  queue = targets.dup
  mutex = Mutex.new
  threads = Array.new(n) do
    Thread.new do
      loop do
        rel = mutex.synchronize { queue.pop }
        break unless rel

        Rubik::AST::Extractor.extract(File.join(root, rel))
      end
    end
  end
  t_par = Benchmark.realtime { threads.each(&:join) }
  puts format("threaded extract (%2d) %8.1f ms total  (Windows/GVL: expect ~no gain)", n, t_par * 1000)
end
