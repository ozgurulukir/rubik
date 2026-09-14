# Bump Bundler Pin in Gemfile.lock

> **Date:** 2026-09-13
> **Repo:** C:\Github\rubik
> **Status:** Plan (not yet approved/implemented)
> **Milestone:** Single-file lockfile fix; no Gemfile change required.

---

## 1. Goal

Restore a **working, stable Bundler pin** in `C:\Github\rubik\Gemfile.lock` so that
`bundle install` / `bundle exec` operate cleanly under the repo's Ruby 4.0.6
environment. The lockfile currently pins `BUNDLED WITH 4.1.0.beta1`, a pre-release
that deliberately must **not** be used (it reproduces the `bundled_gems.rb`
`ArgumentError`), and the earlier `2.5.22` pin is equally broken on Ruby 4.0.

## 2. Background (already investigated — validated below)

| Item | Finding |
| :--- | :--- |
| Ruby | 4.0.6 x64-mingw-ucrt (Windows) |
| Default bundler gem | `4.0.16` (`gem list bundler` → `bundler (4.1.0.beta1, default: 4.0.16, 2.5.22)`) |
| Latest stable remote | `4.0.20` |
| Current lockfile pin | `BUNDLED WITH 4.1.0.beta1` (line 117) — accidentally written by `bundle _4.0.16_ update --bundler`, which resolved to the newest remote **pre-release**. |
| Original pin (pre-accident) | `2.5.22` |
| `2.5.22` on Ruby 4.0 | ❌ `bundle exec` → `bundled_gems.rb:56: wrong number of arguments (given 0, expected 1) (ArgumentError)` — 2.5.x `replace_require` hooks are incompatible with Ruby 4.0's `bundled_gems.rb`. |
| `4.0.16` on Ruby 4.0 | ✅ Verified: `bundle _4.0.16_ exec ruby -e "require 'pathname'"` → OK. |
| `4.1.0.beta1` | ❌ Observed to raise the **same** `ArgumentError` — a beta must not be pinned. |

**Verified lockfile layout** (read of lines 110–117):

```text
110:   minitest (~> 5.20)
111:   rake (~> 13.0)
112:   rubik!
113:   rubocop (~> 1.60)
114:   rubocop-minitest
115:
116: BUNDLED WITH
117:   4.1.0.beta1
```

The version value to change is on **line 117** (the `BUNDLED WITH` header is line
116).

## 3. Steps

### Step 1 — Edit `Gemfile.lock` (the only production change)

- **File:** `C:\Github\rubik\Gemfile.lock`
- **Exact edit (a one-line change at the end of the file):**

```diff
 BUNDLED WITH
-  4.1.0.beta1
+  4.0.16
```

- **Target version rationale:**
  - **Recommended: `4.0.16`** — matches the Ruby 4.0.6 **default** gem. Zero extra
    installs, no network/trust surface, and empirically verified working
    (`bundle _4.0.16_ exec ruby -e "require 'pathname'"` → OK).
  - **Alternative: `4.0.20`** — current latest stable, if the user prefers
    bumping to newest stable rather than matching the default. Same major.minor,
    same integrity story, but requires the gem to be present (install once with
    `gem install bundler -v 4.0.20` or accept bundler installing it for you).
  - **Forbidden: `4.1.0.beta1`** — pre-release; reproduces the bundler
    `ArgumentError`. Do **not** re-pin to it. Do not re-run
    `bundle _4.0.16_ update --bundler` as a means of scoring the pin (that was the
    root cause of the accident).
  - **Forbidden: `2.5.22`** — broken under Ruby 4.0 (the original bug).

### Step 2 — Verify lockfile integrity with Bundler 4.0.16

Run (from `C:\Github\rubik`):

```powershell
bundle _4.0.16_ install
```

- **Expect:** `Bundle complete!` — lockfile resolves successfully, no gems need
  downloading/reinstalling, `Gemfile.lock` not mutated beyond the intended edit.

- **Regression-proof gate:** confirm the pinpointed Bundler version is honored:

```powershell
bundle _4.0.16_ exec ruby -e "require 'pathname'"
```

- **Expect:** exit 0, no output, no `bundled_gems.rb:56` / `ArgumentError`. This
  proves the pinned version runs `require` cleanly (no `replace_require` clash).

- **Sanity check of the runtime relationship:**

```powershell
gem list bundler
```

- **Expect:** `bundler (4.1.0.beta1, default: 4.0.16, 2.5.22)` — confirms the
  target `4.0.16` is the Ruby 4.0.6 default, i.e. a pin that works with **no**
  extra installs.

### Step 3 — Note (NOT a gate): `rake test` load failure from `fiddle`

- `bundle _4.0.16_ exec rake test` is expected to **fail at load time** for an
  unrelated reason: Ruby 4.0 dropped `fiddle` as a default gem, and `reline`
  (transitive dep) needs `fiddle/import` on Windows under `bundle exec`.
- **Out of scope** for this plan unless the reviewer deems it a trivially
  adjacent fix (it is not — it concerns reline/fiddle resolution, not the bundler
  pin).
- **Review gate stance:** a `bundle exec rake test` load failure caused by the
  `fiddle`/`reline` issue must be **accepted as unrelated** and must NOT block
  approval of this bundler-pin change. The failure signature for *this* fix would
  be a bundler/`bundled_gems.rb` error, not a missing-`fiddle/import` error.

### Step 4 — Cleanup (optional)

- The `4.1.0.beta1` bundler gem may be left installed — the lockfile simply stops
  referencing it. If desired, remove it:

```powershell
gem uninstall bundler -v 4.1.0.beta1
```

- **Caution:** must be run WITHOUT ruby-version-dependent default-gem
  complications only if it no longer matters to anything; `4.1.0.beta1` is not a
  default gem so `gem uninstall` is safe, but it is **not required** for this
  plan and should be a separate, explicit step if the user wants it.

## 4. Architecture Decisions

### Decision 1: Pin `4.0.16` (ruby default) over `4.0.20` (newest stable)

- **Approach:** align the lockfile pin with the Bundler that ships as the Ruby
  4.0.6 default (`4.0.16`).
- **Rationale:** (a) zero installs — the gem is already the default; (b) verified
  working on this exact Ruby; (c) principle of least surprise — lockfile matches
  the ambient runtime's default; (d) 4.0.20 offers no known fix relevant to this
  repo and would add an install step and a drifting pin.
- **Trade-off:** we intentionally do not track "newest stable" here; that is a
  policy choice, not a technical one. Note 4.0.20 as the alternative in the
  commit message if the user overrides.

### Decision 2: Do NOT pin a pre-release

- Pinning a beta (`4.1.0.beta1`) is compositionally unsound: pre-releases can
  regress between snapshots, and this specific one already reproduces the
  `ArgumentError`. Keep the lockfile on a stable, present, verified version.

### Decision 3: Avoid re-running `bundle update --bundler` to set the pin

- `bundle _4.0.16_ update --bundler` resolved to the newest remote **pre-release**
  ("newest" can be a beta). The lockfile bump is performed as a **manual, exact
  edit** instead — deterministic and reviewable.

### Decision 4: Keep the change minimal / additive-free

- Only `Gemfile.lock` changes. No Gemfile edit, no dependency additions, no new
  gems in the lockfile. (`Gemfile.lock` content beyond line 117 is untouched —
  same gem set, same `BUNDLED WITH` semantics.)

## 5. Open Questions

1. **Newest-stable vs. ruby-default:** `4.0.16` is the recommendation; does the
   user want `4.0.20` (latest stable) instead? (One-line difference in the same
   edit.)
2. **Gem uninstall of `4.1.0.beta1`:** keep installed (default here) or uninstall?
3. **Out-of-scope `fiddle`/`reline` breakage:** should a follow-up plan be opened
   to make `bundle exec rake test` runnable on Ruby 4.0 (e.g. add `fiddle` to the
   Gemfile or a Windows-only workaround)? Explicitly deferred here.

## 6. Scope / Out-of-Scope

### In scope
- Single one-line edit to `Gemfile.lock` line 117 (`4.1.0.beta1` → `4.0.16`).
- Verification commands in Step 2 (install + require smoke test + gem list).

### Out of scope
- Any `Gemfile` changes, new dependencies, or lockfile gem-set changes.
- Fixing the `fiddle`/`reline` load failure of `bundle exec rake test` (Ruby 4.0
  dropped `fiddle` as a default gem) — documented as a known, unrelated, accepted
  limitation for this plan's review gate.
- Uninstalling `4.1.0.beta1` unless explicitly requested (Step 4).
- Committing; this plan ends at verified working-tree state, then hand off to
  commit pipeline.