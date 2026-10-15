# 🔌 Rubik Plugins and Extensibility Guide (Plugin Architecture)

> **Protocol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability, Reversible Effects & Autonomous Extensions

---

## 📖 1. Introduction and Architectural Principles

Rubik is built on a **Spatiotemporal Plugin and Service Architecture** that enables both developers and autonomous models (`frontier LLMs`) to add new capabilities to the system at `runtime`.

### Core Principles:
1. **LIFO Inverse Effect Contract (Reversible Effects):**
   Every plugin or runtime service (`context.provide`) must register a cleanup handler (`register_disposable { ... }`) that destroys itself when its lifecycle ends, leaving no leftover or zombie threads/processes behind.
2. **Fiber & Context Isolation:**
   Plugins do not pollute global mutable state; all services are bound to the current `Rubik::Runtime::Context` object.
3. **Dual Scope Support (Global & Project Scopes):**
   Plugins and custom tools can be hosted globally for the user (`~/.rubik/tools/`, `~/.rubik/commands/`) or per project (`.rubik/tools/`, `.rubik/commands/`).

---

## 🛠️ 2. Custom Agent Tool Development (`Rubik::Tools::BaseTool`)

To create a new tool that agents can invoke directly, inherit from the `Rubik::Tools::BaseTool` class:

```ruby
# frozen_string_literal: true
# .rubik/tools/database_query.rb

require "rubik/tools/base"

module Rubik
  module Tools
    class DatabaseQueryTool < BaseTool
      def initialize(db_client = nil)
        super(
          name: "database_query",
          aliases: %w[db_query sql_exec run_query],
          description: "Execute a read-only SQL query against the development database",
          risk: :read, # :read, :write veya :execute
          params_schema: {
            type: "object",
            properties: {
              query: { type: "string", description: "SQL query to execute" },
              limit: { type: "integer", description: "Maximum rows to return (default: 50)" }
            },
            required: ["query"]
          }
        )
        @db_client = db_client
      end

      def execute(args = {})
        sql = (args["query"] || args[:query]).to_s.strip
        limit = (args["limit"] || args[:limit] || 50).to_i

        return "Error: query parameter is required." if sql.empty?

        # Güvenlik ve çalıştırma
        results = @db_client ? @db_client.query(sql, limit: limit) : "Mock: Executed #{sql} (limit: #{limit})"
        "Query Results:\n#{results}"
      rescue StandardError => e
        "Database error: #{e.message}"
      end
    end
  end
end
```

### Registering the Tool:
```ruby
# REPL başlatılırken veya runtime context üzerinde:
tool = Rubik::Tools::DatabaseQueryTool.new(my_db)
shell.tool_registry.register(tool)
```

---

## ⚡ 3. Custom REPL Command Development (Bang Commands)

Define commands that the user can run directly with `!` in the REPL shell:

```ruby
# .rubik/commands/db_seed.rb
# Description: Seed the development database with mock records [project]

->(args, output, shell) {
  output.puts "🌱 Seeding development database..."
  # Veritabanı tohumlama mantığı
  output.puts "✅ 50 mock users and 100 orders seeded successfully."
}
```

Invoking from within the REPL:
```bash
rubik (my_project) [main] > !db_seed
🌱 Seeding development database...
✅ 50 mock users and 100 orders seeded successfully.
```

---

## 🧩 4. Custom Language Adapter Development (`Rubik::Adapter::Base`)

Extend Rubik's build, test, and static analysis processes to a new language or test framework:

```ruby
# frozen_string_literal: true

require "rubik/adapter/base"

module Rubik
  module Adapter
    class ElixirAdapter < Base
      def name
        "elixir"
      end

      def test_command
        "mix test"
      end

      def lint_command
        "mix credo"
      end

      def parse_test_output(output)
        passed = !output.include?("failures") && output.include?("0 failures")
        {
          ok: passed,
          failures: output.scan(/\d+\) test .+/),
          summary: output.lines.last.to_s.strip
        }
      end
    end
  end
end
```

---

## 🧬 5. Autonomous Tool and Command Synthesis (`Self-Evolving`)

When frontier LLM models need a custom analysis or transformation that is not part of the standard tool set, they can synthesize their own tools at runtime using the `synthesize_tool` or `synthesize_command` tools.

> **Comprehensive Guide:** For details and live examples of how LLMs evolve Rubik step by step, see the **[`SELF_EVOLUTION.md`](SELF_EVOLUTION.md)** document.

### Autonomous Tool Synthesis Example:
```json
{
  "tool": "synthesize_tool",
  "args": {
    "name": "ast_complexity_analyzer",
    "description": "Calculates cyclomatic complexity of all Ruby methods",
    "code": "->(args) { Rubik::AST::Graph.new.calculate_complexity }"
  }
}
```

The synthesized tool is registered into `@tool_registry` immediately, and in the next step the agent can invoke the tool by the name `ast_complexity_analyzer`.

---

## 🛡️ 6. Security and Best Practices (Security Guardrails)

1. **Path Traversal Prevention:**
   In tools that perform file operations, always use `Buffer::Manager#sanitize_path` or `Platform.path_under?`.
2. **Critical Command Protection:**
   Before running shell commands, call `Rubik::Security::Guard#verify_command_safety!`.
3. **Elm-Style Diagnostics:**
   For input validation and error conditions, use the `Rubik::Tools::DiagnosticReporter` templates instead of bare error messages, so the model can correct itself on the first retry.

---

## 📂 7. Drop-in Plugin Architecture (User Plugins)

Developers can extend Rubik's capabilities without installing a gem. Rubik scans two main directories:
- **Global:** `~/.rubik/plugins/` (system-wide plugins)
- **Project:** `.rubik/plugins/` (project-specific plugins)

Plugins can be placed in these directories as a `.rb` file (e.g. `benim_eklentim.rb`) or as a directory structure (e.g. `benim_eklentim/lib/benim_eklentim.rb`).

### `Rubik.plugin` DSL
Plugins are defined using the standard DSL. Example:

```ruby
# .rubik/plugins/merhaba.rb
Rubik.plugin(:merhaba, version: "1.0.0", description: "Örnek bir eklenti", inject: [:shell]) do |ctx|
  shell = ctx.require(:shell)
  shell.output.puts "Merhaba eklentisi yüklendi!"

  # Temizlik (LIFO Spatiotemporal Unwinding)
  ctx.on_dispose do
    shell.output.puts "Merhaba eklentisi sonlandırıldı."
  end
end
```

### Security (Manifest, Package Inventory, and Transactional Reload)
When plugins are added from the command line with `!plugin add <path>`, they are recorded in the `.manifest.json` file. A single-file plugin is recorded by its file hash. A directory plugin is recorded as a **package inventory**: every file under the package root (relative path → SHA-256) is hashed, so changing, adding, or deleting a helper is detected as drift and the plugin is rejected at load/reload time — not just changes to the entry file. Symlinks (which could escape the package) are refused both when adding and when verifying. Plugins added before the package inventory existed have no consented helper set; they are rejected with an explicit re-consent path: re-add with `!plugin add`, or set `RUBIK_TRUST_OVERLAYS=1` to trust them. Tampered packages are rejected by the security mechanism. The plugin path is never bootstrapped: a plugin file with no entry in the manifest is rejected under all circumstances (unlike the one-time bootstrap rule for command/tool overlays — see SELF_EVOLUTION.md). For command/tool overlays: when cloning a foreign repository, inspect its `.rubik/` directory; sentinel files without a manifest are accepted only with explicit `RUBIK_BOOTSTRAP_OVERLAYS=1` consent.

`!plugin reload <name>` is transactional: existence, whole-package integrity, and definition preparation are verified **before** the running version is unloaded. A missing, tampered, legacy, or syntactically broken replacement returns a failure and leaves the old version running; an activation error rolls the failed replacement's partial inverses back and re-registers the previous version. A successful reload runs the old version's inverses LIFO before the new version activates, so exactly one version is active at any time.
