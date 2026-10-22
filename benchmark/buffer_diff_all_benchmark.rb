# frozen_string_literal: true

require_relative "../lib/rubik"
require "benchmark"
require "tmpdir"

Dir.mktmpdir do |dir|
  manager = Rubik::Buffer::Manager.new(root_dir: dir)
  file_count = 100

  file_count.times do |i|
    rel_path = "file_#{i}.txt"
    full_path = File.join(dir, rel_path)
    File.write(full_path, "line 1\nline 2\n" * 50)
    manager.write(rel_path, "line 1\nline 2 modified\n" * 50)
  end

  # Warm up
  manager.diff_all

  iterations = 50
  time = Benchmark.realtime do
    iterations.times do
      manager.diff_all
    end
  end

  puts format("diff_all (%<count>d dirty files, %<iters>d iterations): %<time>.4fs", count: file_count, iters: iterations, time: time)
  puts format("Average per diff_all call: %<avg>.4fms", avg: time / iterations * 1000)
end
