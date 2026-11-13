# frozen_string_literal: true

# Timing-sensitive unit files (issue #384): wall-clock/perf-budget assertions
# and raw-sleep race sites whose pass/fail flips under 4-worker parallel load
# (three full parallel runs produced zero overlapping failures — load-dependent,
# not code-attached). Excluded from the `RUBIK_TEST_SUITE=stable` parallel gate
# alongside SLOW_UNIT_FILES; they still run in the full serial reference
# (`rake test`), `test:slow` (the overlapping entries), and CI-parity full runs.
# Same format as SLOW_UNIT_FILES so both sets subtract directly from the
# sorted `Dir["test/unit/**/test_*.rb"]` list.
TIMING_SENSITIVE_FILES = [
  "test/unit/test_concurrency_capacity.rb",
  "test/unit/test_ast_persistent_cache.rb",
  "test/unit/test_task_manager.rb",
  "test/unit/test_task_manager_input_failures.rb",
  "test/unit/test_allowed_external_dirs.rb",
  "test/unit/test_synthesis_security.rb"
].freeze
