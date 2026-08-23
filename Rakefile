# frozen_string_literal: true

require "rake/testtask"
require_relative "lib/rubik"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/unit/**/test_*.rb", "test/integration/**/test_*.rb"]
  t.warning = false
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
