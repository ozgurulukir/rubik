# frozen_string_literal: true

# AST semantic-index load benchmark (G14): builds the AST::Graph over a tree,
# then measures index build and repeated lookups. Complements
# bench_ast_extractors.rb (per-file cost decomposition) with an index-level
# view. Usage: ruby dev/bench_ast_index.rb [root_dir]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "benchmark"

root = File.expand_path(ARGV[0] || File.expand_path("..", __dir__))
graph = Rubik::AST::Graph.new

scanner = Rubik::Context::Scanner.new(root_dir: root, native: "off")
files = scanner.scan
supported = Rubik::AST::Extractor.supported_extensions
targets = files.keys.select { |k| supported.include?(File.extname(k).downcase) }
puts "== semantic-index load: #{targets.size} supported files under #{root} =="

build_t = Benchmark.realtime do
  targets.each do |rel|
    graph.index_file(File.join(root, rel), File.read(File.join(root, rel)))
  rescue StandardError
    # benchmark keeps going on individual parse failures
  end
end
puts format("index build          %8.1f ms (%d symbols)", build_t * 1000, graph.symbols.size)

lookup_t = Benchmark.realtime do
  100.times { graph.file_symbols[targets.sample.to_s] }
end
puts format("100 random file lookups %8.2f ms", lookup_t * 1000)

search_t = Benchmark.realtime do
  100.times { graph.search_symbols("test") }
end
puts format("100 substring searches  %8.1f ms", search_t * 1000)
