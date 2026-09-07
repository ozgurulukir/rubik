# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/rubik"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/unit/**/test_*.rb", "test/integration/**/test_*.rb"]
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "lib"
    t.libs << "test"
    t.test_files = FileList["test/unit/**/test_*.rb"]
    t.warning = false
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << "lib"
    t.libs << "test"
    t.test_files = FileList["test/integration/**/test_*.rb"]
    t.warning = false
  end

  Rake::TestTask.new(:fast) do |t|
    t.libs << "lib"
    t.libs << "test"
    slow_tests = FileList[
      "test/unit/test_repl.rb"
    ]
    t.test_files = FileList["test/unit/**/test_*.rb"].exclude(slow_tests)
    t.warning = false
  end
end

desc "Run benchmark suite"
task :bench do
  results = Rubik::Benchmark::Runner.run_all
  report = Rubik::Benchmark::Runner.new.generate_markdown_report(results)
  puts "\n=== Rubik Benchmark Report ==="
  puts report
  puts "===============================\n"
end

task default: :test
