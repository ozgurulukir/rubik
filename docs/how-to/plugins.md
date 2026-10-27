# Author Plugins and Custom Tools

> **Protocol:** [`AGENTS.md`](../../AGENTS.md) — Spatiotemporal Composability, Reversible Effects & Autonomous Extensions

---

## 📖 1. Overview and Architectural Principles

Rubik provides a **Spatiotemporal Plugin and Service Architecture** that enables developers
to extend the agent with custom tools, REPL commands, language adapters, and full drop-in plugins.

### Core Extensibility Invariants
1. **LIFO Inverse Cleanup ($\Omega$):** Every plugin or service registration (`context.provide`)
   registers its explicit inverse (`ctx.on_dispose { ... }`), ensuring no zombie threads or leaked handles remain upon unloading or reloading.
2. **Context Isolation:** Plugins avoid global mutable state; dependencies and capabilities are mediated through `Rubik::Runtime::Context`.
3. **Dual Scoping:** Extensions can be scoped globally across all sessions (`~/.rubik/tools/`, `~/.rubik/commands/`, `~/.rubik/plugins/`)
   or restricted to the current repository (`.rubik/tools/`, `.rubik/commands/`, `.rubik/plugins/`).

---

## 🛠️ 2. How to Create a Custom Agent Tool (`BaseTool`)

To provide an agent tool that the model can invoke during a task, inherit from `Rubik::Tools::BaseTool`:

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
          risk: :read, # :read, :write, or :execute
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

        # Safety and execution
        results = @db_client ? @db_client.query(sql, limit: limit) : "Mock: Executed #{sql} (limit: #{limit})"
        "Query Results:\n#{results}"
      rescue StandardError => e
        "Database error: #{e.message}"
      end
    end
  end
end
```

### Registering the Tool
```ruby
# At REPL startup or on the runtime context:
tool = Rubik::Tools::DatabaseQueryTool.new(my_db)
shell.tool_registry.register(tool)
```

---

## ⚡ 3. How to Create a Custom REPL Bang Command

To define interactive commands executed with `!` in the REPL shell, create a Ruby lambda under `.rubik/commands/`:

```ruby
# .rubik/commands/db_seed.rb
# Description: Seed the development database with mock records [project]

->(args, output, shell) {
  output.puts "🌱 Seeding development database..."
  # Database seeding logic
  output.puts "✅ 50 mock users and 100 orders seeded successfully."
}
```

Invoking from the REPL:
```bash
rubik (my_project) [main] > !db_seed
🌱 Seeding development database...
✅ 50 mock users and 100 orders seeded successfully.
```

---

## 🧩 4. How to Create a Custom Language Adapter (`BaseAdapter`)

Extend Rubik's build, test, and formatting capabilities for a new language:

```ruby
# frozen_string_literal: true

require "rubik/adapter/base"

module Rubik
  module Adapter
    class ElixirAdapter < BaseAdapter
      def initialize
        super("elixir", "mix")
      end

      protected

      # Fallback test command; discovered runners (test.runners config /
      # Runtime::Discovery) take precedence when they are available.
      def default_test_cmd
        "mix test"
      end

      def default_format_cmd(file_path)
        "mix format #{Shellwords.escape(file_path)}"
      end
    end
  end
end
```

---

## 🧬 5. Autonomous Tool and Command Synthesis

When models encounter tasks requiring custom logic, they can synthesize tools and REPL commands
at runtime using `synthesize_tool` or `synthesize_command`.

> **In-depth Explanation:** For the complete architectural rationale and preflight validation pipeline,
> see the [Self-evolution Guide](../explanation/self-evolution.md).

---

## 🛡️ 6. Security Guardrails for Custom Code

1. **Path Traversal Prevention:** Always validate file paths with `Buffer::Manager#sanitize_path` or `Platform.path_under?`.
2. **Command Safety Verification:** Before running external processes, verify commands using `Rubik::Security::Guard#verify_command_safety!`.
3. **Structured Diagnostics:** Return Elm-style actionable messages via `Rubik::Tools::DiagnosticReporter` so models can self-correct on failure.

---

## 📂 7. Drop-in Plugin Architecture (`Rubik.plugin` DSL)

Plugins package multi-file capabilities without requiring gem publication. Rubik discovers plugins in:
- **Global:** `~/.rubik/plugins/` (user-wide)
- **Project:** `.rubik/plugins/` (project-scoped)

Plugins can be single files (e.g. `hello.rb`) or directory packages (e.g. `my_plugin/lib/my_plugin.rb`).

### Defining a Plugin
```ruby
# .rubik/plugins/hello.rb
Rubik.plugin(:hello, version: "1.0.0", description: "Sample telemetry plugin", inject: [:shell]) do |ctx|
  shell = ctx.require(:shell)
  shell.output.puts "Hello plugin initialized!"

  # Cleanup (LIFO Spatiotemporal Unwinding)
  ctx.on_dispose do
    shell.output.puts "Hello plugin unloaded cleanly."
  end
end
```

### Security (Manifest, Package Inventory, and Transactional Reload)
When plugins are added from the command line with `!plugin add <path>`, they are recorded in the `.manifest.json` file. A single-file plugin is recorded by its file hash. A directory plugin is recorded as a **package inventory**: every file under the package root (relative path → SHA-256) is hashed, so changing, adding, or deleting a helper is detected as drift and the plugin is rejected at load/reload time — not just changes to the entry file. Symlinks (which could escape the package) are refused both when adding and when verifying. Plugins added before the package inventory existed have no consented helper set; they are rejected with an explicit re-consent path: re-add with `!plugin add`, or set `RUBIK_TRUST_OVERLAYS=1` to trust them. Tampered packages are rejected by the security mechanism. The plugin path is never bootstrapped: a plugin file with no entry in the manifest is rejected under all circumstances (unlike the one-time bootstrap rule for command/tool overlays — see the [self-evolution guide](../explanation/self-evolution.md)). For command/tool overlays: when cloning a foreign repository, inspect its `.rubik/` directory; sentinel files without a manifest are accepted only with explicit `RUBIK_BOOTSTRAP_OVERLAYS=1` consent.

`!plugin reload <name>` is transactional: existence, whole-package integrity, and definition preparation are verified **before** the running version is unloaded. A missing, tampered, legacy, or syntactically broken replacement returns a failure and leaves the old version running; an activation error rolls the failed replacement's partial inverses back and re-registers the previous version. A successful reload runs the old version's inverses LIFO before the new version activates, so exactly one version is active at any time.

**Trust Boundary:** Manifest verification guarantees the cryptographic integrity and operator consent of plugin files on disk. It does **not** sandbox or isolate the plugin at runtime; once loaded, plugins execute in the host Ruby process with the operator's full permissions. Only load plugins from trusted sources, and audit custom plugin code before adding it.

---

See the [documentation index](../index.md) or return to the [README](../../README.md).
