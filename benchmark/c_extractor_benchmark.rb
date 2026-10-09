# frozen_string_literal: true

require "benchmark"
require_relative "../lib/rubik/ast/c_extractor"

c_code = <<~C
  #include <stdio.h>
  #include <stdlib.h>

  int process_data(int *arr, int len) {
      if (arr == NULL) return 0;
      printf("Processing %d items\n", len);
      int sum = 0;
      for (int i = 0; i < len; i++) {
          sum += calculate(arr[i]);
          log_val(arr[i]);
      }
      void *ptr = malloc(1024);
      if (ptr != NULL) {
          do_something(ptr);
          free(ptr);
      }
      return sum;
  }
C

extractor = Rubik::AST::CExtractor.new("test.c", c_code)
symbols = extractor.extract
fn_symbol = symbols.find { |s| s.name == "process_data" }

puts "Extracted function calls: #{fn_symbol.calls.inspect}"

iterations = 100_000
time = Benchmark.realtime do
  iterations.times { extractor.send(:extract_calls, c_code, "process_data") }
end

gc_before = GC.stat(:total_allocated_objects)
10_000.times { extractor.send(:extract_calls, c_code, "process_data") }
gc_after = GC.stat(:total_allocated_objects)

puts "Benchmark results (#{iterations} iterations):"
puts "  Real time: #{time.round(4)}s"
puts "  Allocated objects per 10k calls: #{gc_after - gc_before}"
