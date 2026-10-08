# frozen_string_literal: true

require "benchmark"
require "set"
require_relative "../lib/rubik/ast/python_extractor"

sample_bodies = [
  <<~PY,
    def process_data(self, items):
        total = 0
        for item in items:
            if validate_item(item):
                res = calculate_subtotal(item, len(items))
                log_info(res)
                total += res
            elif check_fallback(item):
                total += compute_fallback()
            else:
                handle_error(item)
        print("Done:", total)
        return total
  PY
  <<~PY,
    async def fetch_and_parse(url):
        data = await fetch_url(url)
        parsed = parse_json(data)
        super().on_data(parsed)
        validate_schema(parsed)
        save_db(parsed)
        return parsed
  PY
  <<~PY,
    def simple_func():
        pass
  PY
]

def baseline_extract_calls(body, self_name)
  calls = body.scan(/\b([A-Za-z0-9_]+)\s*\(/).flatten.uniq
  calls.reject { |c| c == self_name || ["def", "async", "if", "elif", "else", "for", "while", "return", "print", "len", "range", "super"].include?(c) }
end

EXCLUDED_KEYWORDS = Set.new(
  %w[def async if elif else for while return print len range super]
).freeze

def optimized_extract_calls(body, self_name)
  calls = Set.new
  body.scan(/\b[A-Za-z0-9_]+(?=\s*\()/) do |c|
    calls << c unless c == self_name || EXCLUDED_KEYWORDS.include?(c)
  end
  calls.to_a
end

# Correctness verification
sample_bodies.each_with_index do |body, idx|
  r1 = baseline_extract_calls(body, "process_data")
  r2 = optimized_extract_calls(body, "process_data")
  raise "Mismatch in sample #{idx}: baseline=#{r1.inspect}, optimized=#{r2.inspect}" unless r1 == r2
end

puts "Result parity verified successfully across sample bodies."

iterations = 50_000

GC.start
obj_before_base = GC.stat(:total_allocated_objects)
baseline_time = Benchmark.measure do
  iterations.times do
    sample_bodies.each do |body|
      baseline_extract_calls(body, "process_data")
    end
  end
end
obj_after_base = GC.stat(:total_allocated_objects)
base_allocs = obj_after_base - obj_before_base

GC.start
obj_before_opt = GC.stat(:total_allocated_objects)
optimized_time = Benchmark.measure do
  iterations.times do
    sample_bodies.each do |body|
      optimized_extract_calls(body, "process_data")
    end
  end
end
obj_after_opt = GC.stat(:total_allocated_objects)
opt_allocs = obj_after_opt - obj_before_opt

puts "=== Benchmark: PythonExtractor#extract_calls ==="
puts "Baseline:  #{baseline_time.real.round(6)}s | Allocations: #{base_allocs}"
puts "Optimized: #{optimized_time.real.round(6)}s | Allocations: #{opt_allocs}"
diff = ((baseline_time.real - optimized_time.real) / baseline_time.real * 100).round(2)
alloc_diff = ((base_allocs - opt_allocs).to_f / base_allocs * 100).round(2)
puts "Speedup: #{diff}%"
puts "Allocation Reduction: #{alloc_diff}%"
