# Add `fiddle` as a Runtime Dependency of the rubik Gem

> **Date:** 2026-09-13
> **Repo:** C:\Github\rubik
> **Status:** Approved — ready for implementation
> **Milestone:** Make `bundle exec rake test` load past the Ruby 4.0 `fiddle/import` load-time error; declared in the gemspec, resolved into `Gemfile.lock` via `bundle install`.

---

## 1. Goal

Add `fiddle` as an explicit **runtime dependency** of the rubik gem so fails, renders
under the Ruby 4.0.6 environment this repo runs on.

**Why it is needed:**

- In Ruby 4.0, `fiddle` is no longer a **default gem** (it is still installed as a
  bundled gem: `gem list fiddle` → `fiddle (1.1.8)`), but under `bundle exec` the
  load path is restricted, so `require "fiddle/import"` raises
  `LoadError: cannot load such file -- fiddle/import` unless the gem is declared in
  the bundle.
- `reline` (a declared dependency already, used by `lib/rubik/repl/shell.rb`,
  `lib/rubik/repl/interrupt_handler.rb`) requires `fiddle/import` on Windows
  (`reline/io/windows.rb`). On this Windows environment that turns into a
  **load-time abort** for `bundle _4.0.16_ exec rake test`.

The fix follows the exact established pattern in `rubik.gemspec` for stdlib gems
that Ruby unbundles (Ruby 3.4/3.5 / 4.0): pin the gem explicitly with a
file-reference comment. `fiddle` is intentionally added to the **gemspec only** —
not the Gemfile — so every consumer of the rubik gem gets it as a runtime
dependency.

## 2. Background (already investigated — trusted, do not re-investigate)

| Item | Finding |
| :--- | :--- |
| Ruby | 4.0.6 x64-mingw-ucrt (Windows) |
| `fiddle` status in Ruby 4.0 | ❌ no longer a **default** gem; still installed as a bundled gem `fiddle (1.1.8)` |
| Failure mode | `bundle exec rake test` aborts at load time with `LoadError: cannot load such file -- fiddle/import`; Ruby prints "You can add fiddle to your Gemfile or gemspec to fix this error." |
| Root cause | `reline/io/windows.rb` → `require "fiddle/import"`; `reline` is used by `lib/rubik/repl/shell.rb` |
| External gemspec pattern | stdlib-pinning block at `rubik.gemspec` lines 31–37 (`benchmark`, `logger`, `pstore`, `reline`) |
| Bundler pin (HEAD `1808baa`) | `Gemfile.lock` → `BUNDLED WITH 4.0.16`; bundle operations must use `bundle _4.0.16_` |
| `Gemfile.lock` layout | PATH `rubik (0.1.0)` deps (lines 5–16, alphabetical); GEM specs section (lines 20–…, alphabetical); PLATFORMS already includes `x64-mingw-ucrt` and `x86_64-linux` |
| Current lockfile ions | `fiddle` is **not** present anywhere in `Gemfile.lock` (verified by grep) — clean insertion, no removal |
| Rubocop | `Layout/LineLength` Max: 160 (`.rubocop.yml` lines 49–50) — the comment line below is within limit |

## 3. Steps

### Step 1 — Edit `rubik.gemspec` (the only source change)

- **File:** `C:\Github\rubik\rubik.gemspec`
- **Edit:** add one line to the stdlib-pinning block, directly **after** the
  existing `reline` line (line 37). The `#` comment column is aligned at the same
  column as the existing entries (4 spaces after the string literal — `fiddle` is
  the same width as `logger`).

```diff
   spec.add_dependency "pstore"    # lib/rubik/config/store.rb (yaml/store)
   spec.add_dependency "reline"    # lib/rubik/repl/shell.rb, repl/interrupt_handler.rb
+  spec.add_dependency "fiddle"    # reline 1.x requires fiddle/import in reline/io/windows.rb on Windows (Ruby 4.0 unbundles fiddle)
```

- **Why the comment:** documents *why* this exists — not a direct rubik usage but a
  transitive requirement of `reline` on Windows, and the Ruby 4.0 unbundling
  context. Line length ~146 chars, under the rubocop Max: 160.
- Alternate narrower comment (equally acceptable, implementation choice):

```ruby
spec.add_dependency "fiddle"    # reline/io/windows.rb requires fiddle/import on Windows
```

- Do **not** touch any other line of the gemspec, the Gemfile, the Rakefile, or
  any source file.

### Step 2 — Regenerate the lockfile with Bundler 4.0.16 (NOT `bundle update`)

- **Command (from `C:\Github\rubik`):**

```powershell
bundle _4.0.16_ install
```

(via the ridk shell wrapper — see §5 Environment Notes.)

- **Expect:** `Bundle complete!` — resolution succeeds entirely offline because
  `fiddle (1.1.8)` is already installed as a bundled gem.
- **Expect the lockfile mutation to be additive and minimal:**
  - `PATH` section (rubik deps): `fiddle` inserted alphabetically between
    `diff-lcs (>= 1.5, < 3.0)` (line 6) and `logger` (line 7).
  - `GEM` specs section: `fiddle (1.1.8)` inserted alphabetically between
    `diff-lcs (2.0.0)` (line 23) and `io-console (0.9.2)` (line 24).
  - **`BUNDLED WITH` must remain `4.0.16`.** It must NOT be re-resolved or bumped.
- **Forbidden:** do **not** run `bundle update --bundler` and do **not** run a
  bare `bundle update` — either could re-resolve `BUNDLED WITH` (the bug history
  in this repo: the `4.1.0.beta1` lockfile accident). `bundle install` after a
  gemspec edit never rewrites `BUNDLED WITH`; if it somehow does, stop and report
  rather than shipping the change.
- **Sanity check on PLATFORMS:** `x64-mingw-ucrt` and `x86_64-linux` are already
  present; re-running install on Windows must not prune `x86_64-linux` or add new
  platform entries.

### Step 3 — Verify the lockfile diff

```powershell
git diff Gemfile.lock
```

- **Gate:** the diff shows exactly two insertions (PATH dep + GEM spec, both
  `fiddle`), `BUNDLED WITH` unchanged at `4.0.16`, and nothing else. Also confirm
  `git diff rubik.gemspec` shows exactly the single added line from Step 1.

### Step 4 — Verification commands (all must pass)

Run each inside the repo dir via the ridk wrapper:

1. **`fiddle/import` loads under the bundle:**
   ```bash
   bundle _4.0.16_ exec ruby -e 'require "fiddle/import"; puts :ok'
   ```
   → exit 0 and prints `ok`.
2. **`reline` loads:**
   ```bash
   bundle _4.0.16_ exec ruby -e 'require "reline"; puts :ok'
   ```
   → exit 0 and prints `ok`. Note: on this headless environment `reline` may
   attempt terminal I/O at require time — if it hangs or raises a
   terminal-related error, guard with `TERM=dumb` (and/or redirect stdin/stdout)
   and retry; the meaningful gate is that the `fiddle/import` load error is gone.
   At minimum, Step 1's `require "fiddle/import"` must pass.
3. **Bundle consistency:**
   ```bash
   bundle _4.0.16_ check
   ```
   → prints `The Gemfile's dependencies are satisfied` and exits 0.
4. **Optional — test suite load gate (documented expectation; see §4, not a hard
   pass gate):**
   ```bash
   bundle _4.0.16_ exec rake test
   ```
   → The **gate is that the suite now LOADS** past the previous load-time
   `fiddle/import` abort (minitest files begin running). Pre-existing failures —
   notably the previously observed SIGSEGV and unrelated test failures — are **out
   of scope** and acceptable. Record the observed state (loads vs not, which
   unrelated failures/SIGSEGV appeared) in the implementation report.

## 4. Scope / Out-of-Scope

### In scope
- One-line gemspec edit (`spec.add_dependency "fiddle"`) at `rubik.gemspec`.
- Lockfile regeneration via `bundle _4.0.16_ install`.
- Verification commands in Step 4.

### Out of scope
- **No `Gemfile` change** — the Gemfile stays a thin wrapper; `fiddle` becomes a
  runtime dependency of the gem via the gemspec, which is the point.
- No `Rakefile` change, no source changes, no other gemspec dependencies added.
- NOT fixing the pre-existing test-suite SIGSEGV or unrelated test failures. The
  earlier tree_sitter build env vars are already handled — touch nothing there.
- Do **not** run `bundle update` / `bundle update --bundler`.
- No gem installs — `fiddle (1.1.8)` is already present as a bundled gem.
- Committing is NOT part of this plan — ends at verified working-tree state, then
  hand off to the commit pipeline (`bundle _4.0.16_ exec rake test` may be left
  with pre-existing unrelated failures documented).

## 5. Environment Notes (for whoever implements)

- **Shell:** Windows PowerShell 5.1 (this build tool's shell). Repo commands must
  run through the Ruby dev-kit bash so the right Ruby/bundler and rust toolchain
  are on PATH:
  ```bash
  ridk exec bash -lc 'export PATH="/c/Ruby40-x64/bin:/c/Users/ozgur/scoop/apps/rustup/current/.cargo/bin:$PATH"; cd /c/Github/rubik; COMMAND...'
  ```
- **Bundler version discipline:** always invoke as `bundle _4.0.16_ ...`. Never a
  bare `bundle` (could pick `4.1.0.beta1`), never `--bundler` updates.
- **Output capture through `ridk exec` can be flaky** — empty stdout may still
  mean success. Prefer writing a small script file and echoing an explicit exit
  marker (`echo "RC=$?"`), or rely on the command's exit code and explicit `puts
  :ok` / `Bundle complete!` markers rather than on stdout being faithfully relayed.
- **Where to run:** always `cd /c/Github/rubik` inside the bash invocation — the
  gemspec and Gemfile live at the repo root and bundler must resolve from there.

## 6. Architecture Decisions

- **Add to the gemspec, not the Gemfile (Decision 1 — the core choice).**
  `fiddle` is a runtime requirement of *using* the rubik gem under `bundle exec`
  on Windows/Ruby 4.0, not just a dev-time need. Declaring it in the gemspec makes
  it a true runtime dependency shipped to every consumer; the Gemfile would only
  fix one local checkout. This also matches the existing stdlib-pinning block,
  whose Sentiment is "keep requires green" for the same unbundling shift
  (Ruby 3.4/3.5 → Ruby 4.0).
  *Alternative considered:* adding `fiddle` to the Gemfile's runtime-adjacent
  entries — rejected because the Gemfile is a thin wrapper and gemspec is the
  single source of truth for gem dependencies (SSOT rule).
- **No version constraint.** `fiddle` follows the version that ships with the Ruby
  it runs on (bundled gem; 1.1.8 on this Ruby). Constraining it would force
  re-resolution against Rubygems for an environment-coupled stdlib-adjacent gem.
  Consistent with how `benchmark`/`logger`/`pstore` are pinned (bare, no
  constraint) and with what Ruby's own error message suggests ("add fiddle to your
  Gemfile or gemspec").
  *Alternative considered:* `spec.add_dependency "fiddle", "~> 1.1"` — rejected,
  unnecessary trust/network surface on an already-present bundled gem.
- **Lockfile via `bundle install`, not manual edit.** The lockfile's GEM/PATH
  sections must stay consistent with what bundler resolves; a manual edit risks
  drift and stale `BUNDLED WITH` handling. `bundle _4.0.16_ install` is additive
  and deterministic here because the gem is already installed. Verified against
  the sibling plan's warning: the one thing to police is that `BUNDLED WITH`
  remains `4.0.16`.
- **File-reference comment convention preserved.** Every entry in the
  stdlib-pinning block carries a `# <file paths>` tail comment; the `fiddle` entry
  carries the reline/`fiddle/import` rationale instead of rubik source paths
  because the consumer is transitive (reline), not rubik itself.

## 7. Open Questions

1. **Comment verbosity:** the long single-line comment (~146 chars) vs. the short
   variant (`# reline/io/windows.rb requires fiddle/import on Windows`). Either is
   acceptable; implementer may choose the shorter one for readability. No
   behavioral difference.
2. **`reline` require check on headless env (Step 4 #2):** if `require "reline"`
   attempts terminal I/O, the plan allows guarding with `TERM=dumb` / redirecting
   stdio. If even then `require "reline"` fails on terminal grounds (distinct from
   the `fiddle/import` error), is that acceptable to record as
   environment-specific rather than a blocker? Yes — the hard gate is
   `fiddle/import` loading (Step 4 #1) plus `bundle _4.0.16_ check` (Step 4 #3).
3. **Commit scope:** this plan does not commit. If the user wants the unrelated
   pre-existing SIGSEGV/test failures to be blocked on before committing, that is a
   separate decision for the commit stage — call it out now so it surfaces at
   hand-off.