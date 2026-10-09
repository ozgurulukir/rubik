# 📜 Open Source Attributions & Third-Party Notices

Rubik is built on the shoulders of giants. This document acknowledges and credits the open-source projects, academic research, and engineering communities whose code, ideas, and tools made Rubik possible.

---

## 🍴 1. Forked & Ported Projects

### bash-classify
- **Original Project:** [`bash-classify`](https://github.com/fprochazka/bash-classify)
- **Original Author:** Filip Procházka ([@fprochazka](https://github.com/fprochazka))
- **Original Language:** Python
- **License:** MIT License
- **Rubik Integration:**
  - Ported to pure Ruby under [`lib/rubik/security/classifier/`](lib/rubik/security/classifier/).
  - Includes the comprehensive command database (175 popular CLI tool definition YAML files under [`lib/rubik/security/classifier/commands/`](lib/rubik/security/classifier/commands/)).
  - Adapted to use `tree-sitter` for AST parsing, and extended with first-class **PowerShell** (`pwsh`) cmdlet risk classification and execution policy checking.

```
MIT License

Copyright (c) 2025 Filip Prochazka

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 🏛️ 2. Theoretical & Architectural Foundations

### Spatiotemporal Composability
- **Paper:** *"A Programming Paradigm for Spatiotemporal Composability"*
- **Authors:** Yifan Shi (Peking University, DeepSeek-AI), Wei Zhang (Peking University), Tianyi Cui (DeepSeek-AI)
- **Reference Architecture:** Cordis / Cordiverse Meta-Framework
- **Rubik Implementation:**
  - Theoretical backbone codified in [`AGENTS.md`](AGENTS.md).
  - **Temporal Composability:** Monoidal LIFO Inverse Accumulator ($\Omega$) implemented in [`Rubik::Runtime::Context`](lib/rubik/runtime/context.rb).
  - **Spatial Composability:** Reactive Coeffect Dependency DAG ($\Sigma \vdash C : \tau$) implemented in [`Rubik::Runtime::ComponentFiber`](lib/rubik/runtime/fiber.rb) and [`Rubik::Runtime::Manager`](lib/rubik/runtime/manager.rb).
  - Zero-downtime hot reloading, atomic rollback on activation failure, and leak-free lifecycle management.

---

## 🌳 3. AST Parsing & Multi-Language Ecosystem

### Tree-sitter
- **Project:** [`tree-sitter`](https://github.com/tree-sitter/tree-sitter)
- **Authors:** Max Brunsfeld and the Tree-sitter Authors
- **License:** MIT License
- **Usage:** Fast, incremental, robust concrete syntax tree parsing for multi-language semantic code intelligence, symbol extraction, and command security analysis.

### tree_sitter_language_pack
- **Project:** [`tree-sitter-language-pack`](https://github.com/xberg-io/tree-sitter-language-pack)
- **Maintainer:** xberg-io
- **License:** MIT License
- **Grammars Leveraged:**
  - `tree-sitter-bash`
  - `tree-sitter-powershell`
  - `tree-sitter-ruby`
  - `tree-sitter-python`
  - `tree-sitter-go`
  - `tree-sitter-rust`
  - `tree-sitter-c`
  - `tree-sitter-zig`
  - `tree-sitter-typescript` / `tree-sitter-javascript`

---

## 🛡️ 4. Operating System Sandboxing & Isolation

### Bubblewrap (`bwrap`)
- **Project:** [`bubblewrap`](https://github.com/containers/bubblewrap)
- **Authors:** Project Atomic / Flatpak / GNOME contributors
- **License:** LGPL-2.0-or-later
- **Rubik Integration:**
  - [`Rubik::Sandbox::Driver::BubblewrapDriver`](lib/rubik/sandbox/driver/bubblewrap.rb) utilizes unprivileged user namespaces (`CLONE_NEWUSER`, `CLONE_NEWNET`, `CLONE_NEWPID`) for hardware-enforced filesystem and network confinement without requiring root privileges.

### Container Runtimes (Docker & Podman)
- **Projects:** [`moby/moby` (Docker Engine)](https://github.com/moby/moby) · [`containers/podman`](https://github.com/containers/podman)
- **Licenses:** Apache-2.0 (Docker/Moby) · GPL-2.0-or-later (Podman; libpod)
- **Rubik Integration:**
  - [`Rubik::Sandbox::Driver::DockerDriver`](lib/rubik/sandbox/driver/docker.rb) and [`Rubik::Sandbox::Driver::PodmanDriver`](lib/rubik/sandbox/driver/podman.rb) drive these engines as **external CLI tools only** (no source code incorporated): workspace bind-mounts, memory/CPU/pids limits, and default network-off confinement.
  - [`Rubik::Sandbox::Driver::ProcessDriver`](lib/rubik/sandbox/driver/process.rb) provides the always-available direct host fallback when no kernel-level sandbox is present.

---

## 💎 5. Open Source Ruby Gems & Libraries

| Gem | Author / Maintainer | License | Role in Rubik |
| :--- | :--- | :--- | :--- |
| **`diff-lcs`** | Austin Ziegler | MIT / Artistic / GPL | Longest Common Subsequence unified diff generation and hunk merging ([`Rubik::Buffer::Diff`](lib/rubik/buffer/diff.rb)). |
| **`tty-prompt`** | Piotr Murach | MIT | Interactive command-line select dialogs, multi-choice prompts, and questionnaires. |
| **`tty-spinner`** | Piotr Murach | MIT | Managed non-blocking lifecycle spinners and progress indication. |
| **`tty-markdown`** | Piotr Murach | MIT | Terminal ANSI/colorized Markdown rendering in the interactive REPL. |
| **`tty-which`** | Piotr Murach | MIT | Cross-platform executable binary locator. |
| **`pastel`** | Piotr Murach | MIT | Clean, chainable ANSI terminal coloring and theme painting. |
| **`strings-ansi`** | Piotr Murach | MIT | ANSI-aware string truncation and alignment for REPL formatters. |
| **`reline`** | Hiroshi SHIBATA & Ruby Team | Ruby License / BSD-2-Clause | Line-editing, history navigation, autocompletion hooks, and headless terminal adaptation. |
| **`prism`** | Kevin Newton & Ruby Core Team | MIT | High-performance Ruby parsing and AST extraction ([`Rubik::AST::RubyExtractor`](lib/rubik/ast/ruby_extractor.rb)). |
| **`minitest`** | Ryan Davis & seattlerb | MIT | Fast, modular test suite powering Rubik's 1,690+ unit, integration, and contract tests. |
| **`rubocop`** | Bozhidar Batsov & contributors | MIT | Static code analysis, style enforcement, and architectural hygiene gates. |
| **`benchmark`, `logger`, `pstore`, `reline`, `fiddle`** | Ruby core / rubygems teams | Ruby License / BSD-2-Clause | Ruby stdlib gems pinned explicitly in `rubik.gemspec` as they are unbundled from the default set in Ruby 3.4/3.5. |

---

## 🌐 6. Industry Specifications & Open Protocols

- **Language Server Protocol (LSP):**
  - Specification by Microsoft Corporation (licensed under MIT / CC BY 4.0).
  - Powering Rubik's cross-language diagnostics, symbol outlines, and jump-to-definition.
- **Model Context Protocol (MCP):**
  - Specification and reference architecture by Anthropic, PBC (licensed under MIT License).
  - Powering Rubik's dynamic multi-server tool discovery, stdio transport, and spatiotemporal tool isolation.
- **Server-Sent Events (SSE):**
  - W3C Recommendation standard for streaming real-time LLM token responses and event telemetry.
- **Semantic Versioning 2.0.0:**
  - Specification by Tom Preston-Werner (CC BY 3.0).

---

## ⚖️ 7. License of Rubik

Rubik itself is licensed under the **MIT License**.  
See the [`LICENSE`](LICENSE) file for the full license text.
