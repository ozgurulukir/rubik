# Plan: Refactor `Agent.register` — Extract Command Registration Helpers

**Date:** 2026-08-25
**File:** `lib/rubik/repl/commands/agent.rb`
**Class:** `Rubik::REPL::Commands::Agent`

## Goal

Split the monolithic `self.register(shell)` method (700 lines, complexity 187, cognitive 640) into ~13 private class methods — one per bang command — so `register` becomes a ~30-line dispatcher that calls each helper.

## Extraction Boundaries

Each helper receives `shell` as its sole argument and contains the exact block passed to `shell.register_command(...)`. The `register` method becomes:

```ruby
def self.register(shell)
  register_plan_command(shell)
  register_goal_command(shell)
  register_steps_command(shell)
  register_verbosity_command(shell)
  register_verbose_command(shell)
  register_provider_command(shell)
  register_providers_command(shell)
  register_model_command(shell)
  register_context_command(shell)
  register_test_command(shell)
  register_lint_command(shell)
  register_format_command(shell)
  register_sh_command(shell)
end
```

## Naming Convention

All helpers are `private_class_method` named `register_<command>_command`:

| # | Command | Lines (current) | Helper Name | Description |
|---|---------|-----------------|-------------|-------------|
| 1 | `plan` | 108–158 | `register_plan_command` | Formulate step-by-step plan |
| 2 | `goal` | 160–210 | `register_goal_command` | Autonomous goal loop |
| 3 | `steps` | 212–259 | `register_steps_command` | Manage step budget |
| 4 | `verbosity` | 261–292 | `register_verbosity_command` | Get/set verbosity level |
| 5 | `verbose` | 294–311 | `register_verbose_command` | Toggle verbose mode |
| 6 | `provider` | 313–501 | `register_provider_command` | Manage providers/models |
| 7 | `providers` | 503–519 | `register_providers_command` | List all providers |
| 8 | `model` | 521–650 | `register_model_command` | Switch/view model roles |
| 9 | `context` | 652–745 | `register_context_command` | Manage context window |
| 10 | `test` | 747–766 | `register_test_command` | Run test suite |
| 11 | `lint` | 768–777 | `register_lint_command` | Run linter |
| 12 | `format` | 779–790 | `register_format_command` | Format target file |
| 13 | `sh` | 792–805 | `register_sh_command` | Execute shell command |

## Extraction Rules (No Behavioral Changes)

1. **Pure extract + wire.** Each helper body is the exact `shell.register_command(...)` call (with its block) lifted verbatim from `register`. No logic changes, no refactoring inside blocks.

2. **`private_class_method`.** All 13 helpers are declared as:
   ```ruby
   private_class_method def self.register_plan_command(shell)
     shell.register_command("plan", description: "...") do |args|
       # ... exact same body ...
     end
   end
   ```

3. **Order preserved.** Helpers are defined in the same order as the commands appear in `register`. The `register` method calls them in that same order.

4. **Placement.** All helpers go **after** `register` (i.e., between line 806 and the `end` at line 807). The file structure becomes:
   ```
   module Agent
     extend Base
     # ... existing class methods (sync_default_provider, parse_model_target, parse_model_args) ...
     
     def self.register(shell)          # ~30 lines
       register_plan_command(shell)
       register_goal_command(shell)
       ...
     end
     
     private_class_method def self.register_plan_command(shell)
       ...
     end
     
     private_class_method def self.register_goal_command(shell)
       ...
     end
     
     # ... 11 more helpers ...
   end
   ```

5. **No `next` changes.** The `next` statements inside blocks (e.g., `next` on line 112, `next` on line 450) remain as-is — they exit the block, which is correct behavior inside `shell.register_command`.

6. **No whitespace/formatting changes.** Only structural extraction. Indentation of the extracted blocks stays exactly as it is today (shifted left by one level since they move out of the `register` method body).

## Verification

1. **Primary regression guard** — builds a real `Shell` and asserts all 13 agent commands are registered. A missing helper call or typo'd name causes this test to fail:
   ```powershell
   ruby -Itest test/unit/test_repl_command_decoupling.rb
   ```
   The key test is `test_all_expected_commands_registered` (line 64) which checks `%w[plan goal steps verbosity verbose provider providers model context test lint format sh]` are all keys in `shell.commands`.

2. **Exercise commands through Shell** — runs `!steps` and `!context` via `execute_input`:
   ```powershell
   ruby -Itest test/unit/test_repl_standardized_commands.rb
   ```

3. **Existing tests still pass** (orchestrator loop, step budget — unrelated to command registration but good sanity check):
   ```powershell
   ruby -Itest test/unit/test_agent_step_budget.rb
   ```

4. **Quick smoke — public API** — only `register`, `sync_default_provider`, `parse_model_target`, `parse_model_args` should appear (the 13 helpers are private):
   ```powershell
   ruby -e "require_relative 'lib/rubik/repl/commands/agent'; puts Rubik::REPL::Commands::Agent.methods(false).sort"
   ```

5. **Verify private visibility** — all 13 `register_*_command` helpers should appear here:
   ```powershell
   ruby -e "require_relative 'lib/rubik/repl/commands/agent'; puts Rubik::REPL::Commands::Agent.private_methods(false).sort"
   ```

## Risk Assessment

- **Low risk.** Pure extraction — no logic changes, no new dependencies, no signature changes.
- **No test changes needed.** The public API (`register(shell)`) is unchanged. Tests call `shell.execute_input("!plan ...")` which goes through `register` → helper, same as before.
- **No diff in behavior.** Each block is lifted verbatim. The `shell.register_command` calls are identical.