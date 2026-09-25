require 'benchmark'

# Mock object simulating CommandResult
CommandResultDummy = Struct.new(:write_paths, :read_paths)

# Generate synthetic dataset of 1,000 command results (some with write_paths, some nil)
command_results = 1000.times.map do |i|
  w = (i % 3 == 0) ? ["/tmp/out_#{i}.txt", "/tmp/log_#{i}.txt"] : (i % 5 == 0 ? [] : nil)
  r = (i % 4 == 0) ? ["/tmp/in_#{i}.txt"] : nil
  CommandResultDummy.new(w, r)
end

puts "=== Benchmark: filter_map.flatten vs flat_map.compact ==="
iterations = 5000

GC.start
baseline_time = Benchmark.measure do
  iterations.times do
    all_writes = command_results.filter_map(&:write_paths).flatten
    all_reads = command_results.filter_map(&:read_paths).flatten
  end
end

GC.start
optimized_time = Benchmark.measure do
  iterations.times do
    all_writes = command_results.flat_map(&:write_paths).compact
    all_reads = command_results.flat_map(&:read_paths).compact
  end
end

puts "Baseline (filter_map.flatten):  #{baseline_time.real.round(6)}s"
puts "Optimized (flat_map.compact):   #{optimized_time.real.round(6)}s"
diff = ((baseline_time.real - optimized_time.real) / baseline_time.real * 100).round(2)
puts "Speedup: #{diff}%"

# Correctness check
w1 = command_results.filter_map(&:write_paths).flatten
w2 = command_results.flat_map(&:write_paths).compact
r1 = command_results.filter_map(&:read_paths).flatten
r2 = command_results.flat_map(&:read_paths).compact

raise "Mismatch in write_paths!" unless w1 == w2
raise "Mismatch in read_paths!" unless r1 == r2
puts "Result parity verified successfully."
