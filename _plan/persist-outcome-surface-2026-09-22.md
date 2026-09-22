# Persist-Outcome Surfacing + Provider Catalog Render Dedup

**Date:** 2026-09-22
**Branch:** `fix/persist-outcome-surface`
**Origin:** deferred debts from the model-upsert-dedup candidate (memory) + one bug the exploration phase discovered.

## Problem

1. **Silent persist failures (the reported debt).** `Config#save!` (lib/rubik/config/store.rb:55-112) already returns `{ok: true, path:, scope:}` / `{ok: false, error:}`, but `Config#set` discards the result and returns `typed_val`; the provider-model catalog verbs ignore it too. Every command therefore prints success ("... [Project level (.rubik/config.yml)].") even when the disk write failed. Only `--project`/`--global` writes can fail; session writes never touch disk.
2. **Nested-deletion bug (discovered during exploration).** `save!` deep-merges in-memory `@data` *over* disk data (deep_ops.rb:23-35 keeps disk-only keys) and only prunes deleted *top-level* roots (store.rb:92). So `Config#remove_provider` (deletes a nested key of the `providers` hash) does **not** persist the removal when the provider already exists on disk — the disk copy merges right back. Our 2-day-old test missed it because the fixture provider was never written to disk before removal. `Mcp::Manager#remove_server` dodges the same semantics via raw `config.transaction` store surgery (mcp/manager.rb:74-88), itself silent on failure (RUBIK_DEBUG-gated warn).
3. **Render dup (the reported debt).** `!provider list` (agent_providers.rb:35-48) and `!providers` (197-210) are byte-identical 14-line renderings. `!providers` has zero test coverage.

## Design (decisions)

- **Uniform result hashes** — `set`, `set_model_spec`, `upsert_provider_model`, `remove_provider_model`, `remove_provider`, and the new `delete` return `{ok:, error?, reason?, path?, scope?}`:
  - persisted success → `{ok: true, path:, scope:}`; session/no-write → `{ok: true}` (normalizing away `save!`'s no-op `self` return — `save!` itself is untouched);
  - write failure → `{ok: false, error:}` with `reason: :persist_failed`;
  - unknown provider (verbs) → `{ok: false, error:, reason: :unknown_provider}`.
  - `{ok:, error:}` is the dominant convention in this codebase (overlay_storage, lsp, session, adapter); zero callers consume `set`'s current return, so the change is observably safe.
- **`Config#delete(key, persist:)`** — `set`'s sibling: digs the path out of `@data` (pruning empty ancestors), persists via `save!(persist, deletions: [key])`; `save!` applies the deletion paths to `merged` *after* deep-merge and *before* schema validation. Idempotent: deleting a missing key is a successful no-op.
- **Failure semantics:** the in-memory change is KEPT on failed persist; commands print one honest error line (`Error: could not save to <scope label>: <reason> (change kept for this session only...)`). Reverting would require undoing auto-vivified intermediate hashes for a rare event.
- **Full sweep:** every command surface that persists gets a uniform guard via `Base.report_persist_failure(ctx, res, ...)`; success prints stay per-site. Also aligned: `Mcp::Manager#remove_server` routes through `Config#delete` (drops the raw store surgery), and `add_server` checks `set`'s result.
- **Render dedup:** pin both outputs byte-exact first (test-only commit), then extract `render_provider_catalog(ctx)` as a `private_class_method` helper in `AgentProviders` (precedent: `AgentModels.update_context_limit`). Audience asymmetry preserved: `!provider` is human-only, `!providers` is `audience: :both`.

## Commits

1. `test(repl): pin !providers and !provider list catalog rendering` — shell-level pins, injected temp Config, exact lines incl. `ljust(35)` padding, `cloud` endpoint for Anthropic, empty-models line.
2. `refactor(config): return persist outcome from set and provider-model verbs` (+ direct-call test updates).
3. `fix(config): persist nested deletions through save!` — deletions param, `Config#delete`, route `remove_provider` through it, regression test (provider on disk → remove with persist → reload gone).
4. `refactor(mcp): route remove_server through Config#delete` — drop raw store surgery.
5. `fix(repl): report persist failures instead of silent success` — `Base.report_persist_failure` + guard at every persisting command site; command-level test with a forced-failing config path.
6. `refactor(repl): share provider catalog rendering`.

## Verification

- Fast suite green; full suite green modulo known load-flakes.
- rubocop on all touched files (CRLF `sed -i 's/\r$//'` after every edit).
- GitNexus impact analysis before editing `set`/`save!` (HIGH risk expected — warn user); `detect_changes` clean before merge.

## Out of scope

- `Config#warnings` dead channel (constructor mkdir failures) — separate debt.
- `persist:` typo tolerance (`"SESSION"` case quirk) — pre-existing, untouched.
- `set_model_spec` listener/notify shape — unchanged.
