# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks"
require "rbconfig"
require_relative "lib/rubik"

# Measured slow unit files (wall time > 15s per file in _report/unit_profile.csv,
# produced by `rake test:profile`). Excluded from `test:fast`, isolated in
# `test:slow`. Re-profile after touching thread/sleep-heavy tests and refresh.
SLOW_UNIT_FILES = [
  "test/unit/test_repl.rb",
  "test/unit/test_spatiotemporal_runtime_invariants.rb",
  "test/unit/test_mcp_client.rb",
  "test/unit/test_plugin_repl_integration.rb",
  "test/unit/test_plan_and_goal.rb",
  "test/unit/test_buffer_reminder_and_auto_apply.rb",
  "test/unit/test_mcp_manager_composability.rb",
  "test/unit/test_lsp_manager_and_diagnostics.rb",
  "test/unit/test_sticky_routing.rb",
  "test/unit/test_failed_turn_persistence.rb",
  "test/unit/test_conversation_history.rb",
  "test/unit/test_cli.rb",
  "test/unit/test_synthesis_security.rb",
  "test/unit/test_structured_context_builder.rb",
  "test/unit/test_agent_command_contract.rb",
  "test/unit/test_verbosity_and_step_formatter.rb"
].freeze

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
    t.test_files = FileList["test/unit/**/test_*.rb"].exclude(SLOW_UNIT_FILES)
    t.warning = false
  end

  desc "Run the full suite and regenerate the README test badge from real numbers"
  task :badge do
    sh RbConfig.ruby, "dev/update_test_badge.rb"
  end

  desc "Run only the slow unit files (measured via rake test:profile)"
  Rake::TestTask.new(:slow) do |t|
    t.libs << "lib"
    t.libs << "test"
    t.test_files = FileList[SLOW_UNIT_FILES]
    t.warning = false
  end

  desc "Profile per-file unit test wall time (resumable; CSV in _report/)"
  task :profile do
    sh RbConfig.ruby, "-Ilib", "-Itest", "dev/profile_unit_tests.rb"
  end

  desc "Run all unit tests in one process (boot cost paid once; fast feedback)"
  task :unit_once do
    sh RbConfig.ruby, "-Ilib", "-Itest", "dev/run_unit_once.rb"
  end

  desc "Run unit tests in N parallel worker processes (opt-in; see _plan/varsayilan-test-taski-ve-paralel-strateji-2026-09-14.md)"
  task :parallel, [:workers] do |_task, args|
    # Default 4: the only measured 0-failure configuration on this machine
    # (N=6/8 win wall time but trip timing-fragile tests under load).
    n = (args[:workers] || 4).to_i
    abort "test:parallel requires N >= 1 (got #{args[:workers].inspect})" if n < 1
    sh RbConfig.ruby, "-Ilib", "-Itest", "dev/run_unit_parallel.rb", n.to_s
  end
end

desc "Regenerate the TOOLS.md summary table cells from tool declarations"
task "tools:doc" do
  sh RbConfig.ruby, "dev/generate_tools_doc.rb"
end

desc "Run benchmark suite"
task :bench do
  results = Rubik::Benchmark::Runner.run_all
  report = Rubik::Benchmark::Runner.new.generate_markdown_report(results)
  puts "\n=== Rubik Benchmark Report ==="
  puts report
  puts "===============================\n"
end

namespace :bench do
  desc "Run runtime validation soak, lifecycle, scheduler, and cache benchmarks"
  task :validation, [:epochs] do |_task, args|
    epochs = args[:epochs] || "1000"
    sh RbConfig.ruby, "dev/validate_runtime_capacity.rb", epochs.to_s
  end
end

# Default runs the full suite via single-process loaders: test:unit_once
# (unit) + test:integration. `rake test` (serial loader) is unchanged as the
# full-coverage reference run. See _plan/varsayilan-test-taski-ve-paralel-strateji-2026-09-14.md.
task default: ["test:unit_once", "test:integration"]
