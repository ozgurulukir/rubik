# frozen_string_literal: true

require "benchmark"
require "tempfile"
require "json"
require_relative "../lib/rubik/session/replayer"

class DummyShell
  attr_reader :executed

  def initialize
    @replaying = false
    @executed = 0
  end

  def execute_input(_cmd)
    @executed += 1
  end
end

shell = DummyShell.new
replayer = Rubik::Session::Replayer.new(shell)

# Create temporary session file with 100,000 events
tf = Tempfile.new(["session_bench", ".jsonl"])
100_000.times do |i|
  tf.puts JSON.generate({ "type" => "input", "payload" => "echo #{i}" })
end
tf.close

puts "Benchmarking session replayer with 100,000 lines (#{File.size(tf.path)} bytes)..."

GC.start
alloc_before = GC.stat(:total_allocated_objects)
time = Benchmark.realtime do
  replayer.replay_file(tf.path)
end
alloc_after = GC.stat(:total_allocated_objects)

puts "Execution time: #{format('%.4f', time)} seconds"
puts "Total allocated objects: #{alloc_after - alloc_before}"
puts "Executed events: #{shell.executed}"

tf.unlink
