# Contributing to Rubik

Thanks for your interest in improving Rubik — an AI coding-agent CLI built on a
revertible-effect, coeffect-driven runtime (see [`AGENTS.md`](AGENTS.md) for the
architecture protocol).

## Development Setup

- **Ruby:** 3.4+ (`ruby -v`; CI runs 3.4 and 4.0). Windows is the first-class development
  platform (RubyInstaller with DevKit, or Scoop); Linux/macOS work as well.
- **Rust toolchain (Windows only):** `tree_sitter_language_pack` publishes no
  Windows prebuilt, so it compiles from source. Install Rust with the GNU target
  and export `RUST_TARGET=x86_64-pc-windows-gnu` plus `BINDGEN_EXTRA_CLANG_ARGS`
  before `bundle install` — copy the exact recipe from
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
- **Install:** `bundle install`

## Running the Checks

```bash
bundle exec rake              # default: full unit suite (single-process) + integration
bundle exec rake test:fast    # measured-slow files excluded
bundle exec rake test:slow    # the 16 isolated slow files
bundle exec rubocop           # zero-warning policy, repo-wide
```

`rake test:profile` records per-file wall time into `_report/unit_profile.csv`
(gitignored) — refresh it after touching thread/sleep-heavy tests. See
[Testing guide](docs/development/testing.md) for naming conventions, agent-loop test templates,
and the flaky-test policy.

## Commits and Pull Requests

- **Conventional Commits:** `type(scope): imperative summary` — types: `feat`,
  `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`; subject
  ≤ 72 chars, lowercase, no trailing period.
- The body explains **why**, not what; link the driving context (`Closes #123`).
- One logical change per commit — never mix refactors with behavior changes.
- PR titles follow the same format, so squash-merges keep history consistent.
- CI runs `lint`, `test`, and `runtime-validation` (runtime capacity soak) on
  every PR; all must pass before merge.

## Security

Do **not** open public issues for vulnerabilities. Use GitHub **private
vulnerability reporting** (repository Security tab → *Report a vulnerability*) —
see [`SECURITY.md`](SECURITY.md) for the threat model and verification surface.

## Documentation

English docs are the source of truth; Turkish translations (`*.tr.md`) are
allowed to lag behind them. Browse the [documentation index](docs/index.md) for
the current guide locations. The generated `TOOLS.md` summary table is updated
with `rake tools:doc`; `CHANGELOG.md` is append-only.

---

See the [documentation index](docs/index.md) or return to the [README](README.md).
