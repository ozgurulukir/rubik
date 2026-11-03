# frozen_string_literal: true

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
  "test/unit/test_verbosity_and_step_formatter.rb",
  "test/unit/test_concurrency_capacity.rb"
].freeze
