# Plan: model-upsert dedup (deferred debt from Candidate 06)

**Date:** 2026-09-22 · **Branch:** `refactor/model-upsert-dedup` · **Source debt:** rubik-command-context memory

## Problem

The "provider-model upsert stanza" is hand-copied across `!model` and `!provider`
branches — fetch `providers.<name>` spec, empty-check, dup the `models` array,
reject the same-name entry (`m.is_a?(Hash) ? m["name"] : m.to_s` shape knowledge),
append `{ "name" => ..., "context_limit" => ... }`, `config.set`, then the
reload+resync tail (`llm_registry.load_from_config` + `resync_llm_route!`).

8 sites in 2 files:

| Site | Check | Mutation |
| --- | --- | --- |
| agent_models `!model add` | yes | upsert |
| agent_models `!model context <limit>` (2-arg) | **no** | upsert |
| agent_models `!model context <role> <limit>` (3-arg) | **no** | upsert |
| agent_models `!model context <p> <m> <limit>` (4-arg) | yes | upsert |
| agent_providers `!provider add` | n/a (creates) | set + tail |
| agent_providers `!provider add-model` | yes | upsert |
| agent_providers `!provider remove-model` | yes | reject-only |
| agent_providers `!provider set-context` | yes | upsert |

Plus `!provider set <field>` (fetch+probe+tail) and `!provider remove` (tail only).
The tail pair also hides a 9th copy in `ConfigWiring.wire_llm_change`.

## Design (Clean — matches recorded preference)

1. **Config owns the storage shape** (`lib/rubik/config.rb`, next to
   `set_model_spec`, its existing sibling):
   - `provider_spec(provider)` — read probe; nil when unknown/empty spec.
   - `upsert_provider_model(provider, model, context_limit:, persist: nil)` — bool.
   - `remove_provider_model(provider, model, persist: nil)` — bool (absent model
     = successful no-op, matching historical UX).
   Commands ask intent; Config never prints.
2. **One named effect for the tail:** `Shell#refresh_llm_registry!` in
   lifecycle.rb = `llm_registry.load_from_config` + `resync_llm_route!`;
   delegated on `CommandContext`; `wire_llm_change` reuses it (SSOT for the pair).
   CommandContext surface grows 52 → 53, freeze test updated in the same commit.
3. **Behavioral alignment (disclosed):** the 2-arg/3-arg `!model context`
   branches had no missing-provider check and would fabricate a provider spec
   (`{"models" => [...]}` — no type/endpoint) out of a broken config. They now
   share the 4-arg branch's `Provider '...' not found.` path. Unreachable under
   healthy config; aligns them with the adjacent sub-branch of the same command.

## Commits

1. `refactor(config): name provider-model catalog mutations` — Config methods +
   `test_config_provider_models.rb`.
2. `refactor(repl): route provider commands through Config catalog mutations` —
   effect + ctx + wiring + both command files + ctx surface test + new
   missing-provider pins in `test_dynamic_llm_providers.rb`.

## Verification

- New Config tests + `test_dynamic_llm_providers.rb`, `test_command_context.rb`,
  `test_agent_command_contract.rb`, guard tests individually, then
  `bundle exec rake test:fast` and full suite; rubocop on touched dirs.
- GitNexus `detect_changes` before merge; impact analysis done (risk UNKNOWN →
  text-search confirmed: `AgentModels`/`AgentProviders` registered only from
  `commands/agent.rb`; `set_model_spec` callers = 2 command sites + tests).
- 2 code-reviewer passes + silent-failure-hunter (missing-provider paths touched).

## Out of scope (noted)

- `!provider list` vs `!providers` duplicate catalog rendering (~14 lines) —
  separate micro-commit if trivial, else follow-up.
- `!model set` branches keep `set_model_spec` + `resync_llm_route!` only (roles,
  not catalog — reload correctly absent today).
