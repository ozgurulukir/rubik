# Rubik

English | [Türkçe](README.tr.md)

[![Build](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Gem version](https://img.shields.io/gem/v/rubik.svg)](https://rubygems.org/gems/rubik)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ruby 3.4+](https://img.shields.io/badge/ruby-3.4%2B-red.svg)](https://www.ruby-lang.org/)
[![Coverage reports](https://img.shields.io/badge/coverage-CI%20artifacts-blue.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Test Suite](https://img.shields.io/badge/tests-see%20CI-blue.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)

## About

Rubik is a Ruby terminal coding agent and interactive REPL. It connects an LLM to
workspace tools for reading and changing code, while staging file edits in a
reviewable in-memory buffer. Developers can use it as a CLI or embed its runtime
from Ruby with `require "rubik"`.

Rubik is for developers who want an agent in their terminal and control over how
its changes reach disk. It supports OpenAI-compatible providers, Anthropic, and
local Ollama. Its security checks and optional OS sandbox are described in
[Security](SECURITY.md).

## Quickstart

**Prerequisites:** Ruby 3.4 or later and an OpenRouter API key for this example.
The gem is the shortest install path:

```sh
gem install rubik
```

Set the key in your shell, then start Rubik. Replace the example value with your
key:

```sh
export OPENROUTER_API_KEY="your-key"
rubik
```

In PowerShell:

```powershell
$env:OPENROUTER_API_KEY = "your-key"
rubik
```

At the REPL prompt, register the provider and choose a model:

<!-- markdownlint-disable MD013 -->

```text
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-sonnet-5.5 --context=200000 -g
!model openrouter/anthropic/claude-sonnet-5.5
```

<!-- markdownlint-enable MD013 -->

Then enter a prompt at the REPL:

```text
Summarize the files in this project.
```

Use `!diff` to review staged file changes and `!apply` to write them to disk. See the
[first-session tutorial](docs/tutorials/first-session.md) for platform-specific
credential setup and a longer walkthrough. Windows gem installation may compile
a dependency from source; see the [installation guide](docs/how-to/installation.md).

> **Safety note:** Model-generated code and commands can be incorrect or unsafe. Review
> changes with `!diff` and run tests before relying on them. For strict human approval
> of **buffered file changes only**, set `buffer.auto_apply: manual` and
> `buffer.model_can_apply: false`. These settings do not gate shell commands or
> background processes: the command safety gate checks them, but allowed commands run
> without a separate per-command approval prompt. The OS sandbox is disabled by default;
> run untrusted code in an isolated environment. See [Security](SECURITY.md).

## Features

1. **Core · Cross-platform CLI.** Run the terminal agent and REPL on Linux,
   macOS, or Windows. The CI matrix covers Ubuntu with Ruby 3.4 and 4.0, and
   macOS and Windows with Ruby 4.0. In the Windows CI environment, gem
   installation compiles a native dependency with the Rust GNU toolchain. See
   the [installation guide](docs/how-to/installation.md).
2. **Core · Staged file edits.** Model writes go to an in-memory virtual buffer;
   inspect them with `!diff`, apply them with `!apply`, or discard unapplied
   edits with `!undo`.
3. **Core · Review control and write semantics.** To require operator approval
   for buffered file changes, set `buffer.model_can_apply: false` together with
   `buffer.auto_apply: manual`. This does not add approval prompts for shell
   commands or background processes; see [security practices](SECURITY.md). Each
   file is written atomically, but a multi-file apply is not a transaction: a
   partial failure leaves the remaining changes dirty and reports applied,
   failed, and pending files. See [buffer configuration](docs/how-to/configuration.md).
4. **Core · Multiple workspace roots.** Add sibling or external directories as
   read-only roots by default, or allow writes with `--rw`; additional roots can
   join code search and the AST index. See the [`!workspace` commands](docs/reference/commands.md).
5. **Core · Guarded command execution.** Commands pass through Rubik's safety
   checks. Bubblewrap, Docker, or Podman isolation is optional and disabled by
   default. See [security practices](SECURITY.md).
6. **Models · Provider and role routing.** Connect OpenAI-compatible endpoints,
   Anthropic, OpenAI, or local Ollama, then assign models to default, fast, and
   advanced roles or use task-based routing. See [provider configuration](docs/how-to/configuration.md).
7. **Code intelligence · Hybrid AST.** Prism parses Ruby; Tree-Sitter grammars
   cover Python, Go, Rust, TypeScript, TSX, JavaScript, C, C++, and Zig. Symbol
   and call-graph indexing can warm in the background and persists to a local
   cache. If Tree-Sitter is unavailable, Rubik can use regex extractors, which
   have structural limits. Parsing errors have structured statuses, and a
   failed re-index preserves previously indexed symbols. See [architecture](docs/explanation/architecture.md).
8. **Code intelligence · Live LSP diagnostics.** Configured language servers
   can start on demand and return compiler or linter diagnostics after edits.
   Missing or failing servers do not block a session; Rubik falls back to its
   built-in syntax and AST analysis. See [language-server setup](docs/how-to/language-servers.md).
9. **Code intelligence · Native fast paths.** When available, ripgrep and Git
   accelerate search and context scanning; Rubik falls back to pure Ruby when
   those binaries are missing or native paths are disabled. Control them through
   `tools.native` or `RUBIK_NATIVE`. See [configuration](docs/how-to/configuration.md).
10. **Extensions · Runtime synthesis.** The model can create REPL commands and
    tools during a session. Managed runtime effects register cleanup actions
    and unwind them in LIFO order. See [self-evolution](docs/explanation/self-evolution.md).
11. **Extensions · Plugins.** Load or reload drop-in Ruby plugins from user or
    project directories. SHA-256 manifests detect modified files, but plugins
    execute arbitrary Ruby in the host process and are not sandboxed. See the
    [plugin guide](docs/how-to/plugins.md).
12. **Extensions · MCP servers.** Connect external stdio servers and expose
    discovered tools through Rubik's registry. Lifecycle cleanup removes proxy
    tools and attempts to stop child processes when the server is disconnected.
    See [MCP commands](docs/reference/commands.md).
13. **Recovery · Live service repair.** Inspect runtime state, verify a
    replacement command in a disposable context, then promote it without
    restarting the process. Failed promotion or persistence unwinds session
    changes; if a previous service cannot be restored, the repair result reports
    incomplete rollback. Successful operator configuration saves remain in
    place. See [runtime repair](docs/explanation/runtime-repair.md).
14. **Long sessions · Structured goal ledger.** The `!goal` loop keeps a
    revision-guarded record of objectives, tasks, findings, and decisions;
    current state survives compaction, and configured verification checks run
    at step boundaries. See [goal commands](docs/reference/commands.md).
15. **Long sessions · Context pruning.** A pruner can propose what to keep,
    drop, or summarize; the harness validates the plan and applies it at a turn
    boundary. The operator can also invoke it with `!prune`. See [pruner settings](docs/how-to/configuration.md).
16. **Long sessions · Vakanüvis annals.** When configured, the chronicler
    records session turns and subagent events; its distiller can build memory
    notes and a wiki skeleton. See [runtime architecture](docs/explanation/architecture.md).
17. **Interaction · Live monitoring and TUI.** Choose quiet, normal, verbose,
    or debug output. The interface combines a statusline, spinner, Markdown
    renderer, colored diff view, and interactive `!agents` board. `NO_COLOR` and
    pipe mode fall back to plain text, and session logs omit ANSI codes. See
    [UI configuration](docs/how-to/configuration.md).
18. **Runtime · Cooperative I/O concurrency.** A pure-Ruby Fiber Scheduler can
    overlap supported blocking I/O on one thread; it does not parallelize CPU
    work; disable it with `RUBIK_FIBER_SCHEDULER=off`. The capacity harness
    exercises lifecycle checks at 1,000 epochs, 100 and 1,000 concurrent loopback
    requests, and AST-cache behavior. See [architecture](docs/explanation/architecture.md)
    and [testing](docs/development/testing.md).

## Documentation

Browse the [documentation index](docs/index.md) for tutorials, how-to guides,
references, architecture explanations, and development guidance. The
[changelog](CHANGELOG.md) records releases.

## Contributing and policies

[Contributing](CONTRIBUTING.md) · [Code of Conduct](CODE_OF_CONDUCT.md) ·
[Security policy](SECURITY.md) · [License](LICENSE)
