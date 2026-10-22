# frozen_string_literal: true

require_relative "../lib/rubik"
require "benchmark"
require "tmpdir"
require "fileutils"

puts "Setting up test repository fixture..."
Dir.mktmpdir("rubik_bench_all_files") do |dir|
  # Populate .git directory with typical git object structure
  git_objects = File.join(dir, ".git", "objects")
  FileUtils.mkdir_p(git_objects)
  10_000.times { |i| File.write(File.join(git_objects, "obj_#{i}"), "git object content") }

  # Populate regular project files
  50.times do |d|
    dpath = File.join(dir, "src", "module_#{d}")
    FileUtils.mkdir_p(dpath)
    20.times { |f| File.write(File.join(dpath, "file_#{f}.rb"), "def hello; :world; end\n") }
  end

  File.write(File.join(dir, ".gitignore"), "log/\n")
  FileUtils.mkdir_p(File.join(dir, ".github", "workflows"))
  File.write(File.join(dir, ".github", "workflows", "ci.yml"), "name: CI\n")

  manager = Rubik::Buffer::Manager.new(root_dir: dir)

  iterations = 20
  puts "Running Rubik::Buffer::Manager#all_files #{iterations} times..."

  time = Benchmark.measure do
    iterations.times do
      files = manager.all_files
    end
  end

  result_sample = manager.all_files
  puts "Total files returned: #{result_sample.size}"
  puts "Execution time: #{time.real.round(4)} seconds (avg: #{(time.real / iterations * 1000).round(2)} ms/op)"
end
