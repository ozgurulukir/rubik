# 🌌 Protocol for Spatiotemporal Composability & Self-Evolving Runtimes

> **Theoretical Reference:** *"A Programming Paradigm for Spatiotemporal Composability"*
> **Authors:** Yifan Shi (Peking University, DeepSeek-AI), Wei Zhang (Peking University), Tianyi Cui (DeepSeek-AI)
> **Reference Architecture:** Cordis / Cordiverse Meta-Framework

---

## 🎯 Executive Overview

Modern software architectures—spanning plugin ecosystems, modular kernels, and self-evolving AI agent harnesses—demand **dynamic composability**: the ability to load, reconfigure, hot-swap, and unload components at runtime without restarting the host process or losing accumulated state.

This specification unifies **Revertible Effects** (Temporal Composability) and **Reactive Coeffects** (Spatial Composability) into a single, cohesive **Context-Driven Programming Paradigm**.

---

## 🏛️ 1. Theoretical Pillars & Invariants

```
                        ┌──────────────────────────────────────────────┐
                        │        SPATIOTEMPORAL COMPOSABILITY          │
                        └──────────────────────┬───────────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
     ┌───────────────────────────────────┐           ┌───────────────────────────────────┐
     │      TEMPORAL COMPOSABILITY       │           │       SPATIAL COMPOSABILITY       │
     │        (Revertible Effects)       │           │        (Reactive Coeffects)       │
     ├───────────────────────────────────┤           ├───────────────────────────────────┤
     │ • Inverses paired by construction │           │ • Explicit dependency contracts   │
     │ • Monoidal LIFO accumulator (Ω)   │           │ • Dynamic satisfaction tracking   │
     │ • Atomic failure rollback         │           │ • Reactive state transitions      │
     └───────────────────────────────────┘           └───────────────────────────────────┘
```

### A. Temporal Composability (Revertible Effects)
- **Inverse by Construction:** Every effectful operation on the environment (mutations, event listeners, timer registrations, network bindings, UI mounts) must return or register its explicit inverse transformation at the point of application.
- **Monoidal Accumulator (Ω):** All effects generated within a component's lifecycle are tracked in a scoped accumulator Ω. Upon component removal or reload, accumulated inverses are executed in strict reverse chronological order (LIFO).
- **Soundness of Rollback (A(σ) ∼ σ₀):** Reverting a component must restore the context to an observational state equivalent to before the component was applied.
- **Failure Reversibility:** If activation fails midway, the partial inverse accumulator must execute immediately to restore the environment to its exact prior state.

### B. Spatial Composability (Reactive Coeffects)
- **Explicit Coeffect Specifications:** Components must never query untyped global registries or ambient singletons. Required capabilities/services must be declared explicitly as typed coeffect dependencies (Σ ⊢ C : τ).
- **Reactive State Transitions:** When the environment context changes (a service is registered, updated, or unregistered), the runtime classifies the transition for each dependent component:
  - **`Activating`**: Coeffects newly satisfied ⇒ transition component from `Pending` to `Active`.
  - **`Deactivating`**: Required coeffects lost ⇒ gracefully unwind and transition component from `Active` to `Pending`.
  - **`Neutral`**: Irrelevant change ⇒ no lifecycle perturbation.

### C. The Unified Context Paradigm
- **Context-Mediated Operations:** All side effects and service consumptions are strictly mediated through an explicit `Context` object (`ctx`).
- **Scoping & Sub-Contexts:** Creating sub-features or child plugins creates a derived sub-context `ctx.extend()`. Disposing a parent context automatically disposes all child contexts and their accumulated effects recursively.

---

## 🔄 2. Fiber Lifecycle State Machine

Every running component instance (Fiber) obeys the following operational transition calculus:

```
                          [ Component Registered ]
                                     │
                                     ▼
                              ┌─────────────┐
                    ┌─────────┤   PENDING   │◄────────────────────────┐
                    │         └──────┬──────┘                         │
                    │                │ Coeffects Satisfied            │
                    │                │ (Run Factory + Track Inverses) │ Coeffects Lost /
                    │                ▼                                │ Unload Requested
     Unload While   │         ┌─────────────┐                         │ (Execute Inverses
     Pending        │         │   ACTIVE    ├─────────────────────────┘  in LIFO Order)
                    │         └──────┬──────┘
                    │                │ Unhandled Error during Load
                    │                ▼
                    │         ┌─────────────┐
                    │         │   FAILED    │ (Execute Partial Inverses ->
                    │         └──────┬──────┘  Atomic Context Rollback)
                    │                │
                    ▼                ▼
              ┌─────────────────────────────┐
              │          DISPOSED           │
              └─────────────────────────────┘
```

### Lifecycle Transition Rules

| Initial State | Event / Trigger | Target State | Invariant Action |
| :--- | :--- | :--- | :--- |
| **`Unloaded`** | `register(component)` | **`Pending`** | Calculate initial coeffect satisfiability. |
| **`Pending`** | Coeffects Satisfied | **`Active`** | Instantiate fiber, track effect inverses in accumulator Ω. |
| **`Active`** | Coeffects Lost | **`Pending`** | Execute Ω in LIFO order; preserve persistent state. |
| **`Active`** | Error during activation | **`Failed`** | Execute partial Ω; report failure; restore prior state. |
| **`*`** | Explicit Unload | **`Disposed`** | Full unwind of Ω; remove fiber from registry. |

---

## 🤖 3. Directives for AI Agent Tool Harnesses & Self-Evolution

When building autonomous agents capable of runtime tool synthesis, dynamic skill loading, and self-modification:

1. **Zero-Downtime Tool Swapping:** Dynamic tool additions and updates must never invalidate existing conversation session state, memory graphs, or in-flight tasks.
2. **Deterministic Tool Registration:**
   - Register tool handler along with its unregister callback into `ctx`.
   - On skill update/reload, unregister the old tool version before activating the new version.
3. **Circular Dependency Avoidance:** Statically inspect the declared coeffect dependency DAG to prevent deadlocks before executing lifecycle transitions.
4. **Session Isolation:** Isolate experimental or self-generated code within a disposable sub-context (`ctx.extend()`). If the synthesized code fails verification, dispose the sub-context to instantly clean up all side effects.

---

## 💻 4. Implementation Reference Patterns (Ruby)

### A. Ruby Context Implementation

The following `Context` class captures the essence of revertible effects and coeffects. It uses a `Proc`-based LIFO stack for cleanup and a service registry with parent lookup. Two zero-restart rules (§6) are built in: `provide` keeps exactly **one** inverse per key (re-providing swaps the value instead of stacking inverses), and a child context disposed before its parent prunes itself — plus its now-dead inverse — from the parent, so repeated open/close cycles return the accumulator to its baseline instead of growing forever. The hardened production version is `Rubik::Runtime::Context` (`lib/rubik/runtime/context.rb`): the same rules with monitor-based thread safety, error-isolated inverses and legacy-alias resolution, omitted here for clarity.

```ruby
class Context
  def initialize(parent = nil)
    @parent = parent
    @services = {}
    @inverses = {}   # subject (service key or child) -> its ONE registered inverse
    @cleanups = []   # LIFO stack of procs (inverses)
    @sealed = false  # true while dispose is draining
  end

  # Register a revertible effect inverse (LIFO order)
  def on_dispose(&cleanup)
    @cleanups.push(cleanup)
    cleanup
  end

  # Provide a service with exactly ONE delete-inverse per key for the
  # context's lifetime: re-providing swaps the value but never stacks a
  # second inverse into the accumulator (§6 zero-restart rule).
  def provide(name, service)
    @services[name] = service
    @inverses[name] ||= on_dispose { @services.delete(name) }
  end

  # Symmetric retraction: remove a service AND its inverse, so provide/
  # unprovide cycles return the accumulator to its baseline.
  def unprovide(name)
    @services.delete(name)
    @cleanups.delete(@inverses.delete(name))
  end

  # Resolve a coeffect dependency, walking up the parent chain
  def require(name)
    return @services[name] if @services.key?(name)
    return @parent.require(name) if @parent
    raise "Required coeffect '#{name}' is not satisfied in the context."
  end

  # Create a scoped child context. The parent tracks the child through its
  # cascade inverse so a child disposed early can retract both itself and
  # the now-dead inverse from the parent.
  def extend
    child = Context.new(self)
    @inverses[child] ||= on_dispose { child.dispose }
    child
  end

  # Called by a disposed child on its parent — after the child has fully
  # released its own state (production code releases its lock first, so
  # child disposal never acquires an ancestor lock). Extend/dispose cycles
  # (per-turn scopes, reconnects, tool epochs) therefore stay flat.
  def prune_child(child)
    return if @sealed  # parent is draining; its cleanup covers the child
    @cleanups.delete(@inverses.delete(child))
  end

  # Unwind all accumulated effects in strict reverse order. A failing
  # inverse must never abort the unwind (§5): report it and keep draining —
  # half-unwound state is worse than a failed cleanup. The seal makes a
  # cascading child's prune a no-op while we iterate.
  def dispose
    @sealed = true
    while (inverse = @cleanups.pop)
      begin
        inverse.call
      rescue StandardError => e
        warn "[Context] dispose inverse failed: #{e.class}: #{e.message}"
      end
    end
    @inverses.clear
    @parent&.prune_child(self)
  end
end
```

### B. Component Example: Analytics Plugin

This example demonstrates a component that declares dependencies (`database`, `http_server`), registers a route, and starts a periodic timer—all with automatic cleanup.

```ruby
AnalyticsPlugin = Struct.new(:ctx, :config) do
  def self.name
    'analytics-plugin'
  end

  # Declare required coeffects
  REQUIRED = ['database', 'http_server']

  def apply
    # Guaranteed to run ONLY when 'database' and 'http_server' are ACTIVE
    db = ctx.require('database')
    interval = config[:heartbeat_interval_ms] || 5000

    # A. Revertible HTTP Route Registration
    ctx.require('http_server').get('/api/analytics') do
      db.query('SELECT * FROM metrics ORDER BY timestamp DESC LIMIT 50')
    end
    # register inverse: remove the route later
    ctx.on_dispose do
      ctx.require('http_server').remove_route('/api/analytics')
    end

    # B. Revertible Timer (inverse registered immediately)
    timer = Thread.new do
      loop do
        sleep interval / 1000.0
        puts '[Analytics] Heartbeat check...'
      end
    end
    ctx.on_dispose { timer.kill; puts '[Analytics] Timer cleared cleanly' }
  end
end
```

**Usage with a runtime:**

```ruby
runtime_ctx = Context.new
runtime_ctx.provide('database', DatabaseService.new)
runtime_ctx.provide('http_server', HttpServer.new)

# Register and activate the plugin (lifecycle managed by a runtime)
plugin = AnalyticsPlugin.new(runtime_ctx, endpoint: 'https://example.com')
plugin.apply

# Later, when the plugin is unloaded or coeffects change:
runtime_ctx.dispose  # Executes all registered inverses in LIFO order
```

### C. Scoped Sub-Context for Isolation

```ruby
parent_ctx = Context.new
parent_ctx.provide('database', db_service)

experiment_ctx = parent_ctx.extend   # child context

# Register experimental resources inside the sub-context
experiment_ctx.on_dispose { puts 'Cleaning up experiment side effects' }

# Simulate failure / cleanup
experiment_ctx.dispose               # only cleans experiment_ctx, parent_ctx remains intact
```

### D. Modular Sandbox Driver Registration with Revertible Inverses (Firejail Example)

This example demonstrates how an external plugin dynamically registers a custom sandbox driver (e.g. `FirejailDriver`) into the runtime using `ctx`, ensuring its inverse unregistration is registered in $\Omega$ for automatic cleanup upon plugin unloading or reloading.

```ruby
FirejailPlugin = Struct.new(:ctx, :config) do
  def self.name
    'firejail-plugin'
  end

  def apply
    # Register FirejailDriver into Rubik's dynamic Driver registry.
    # The inverse unregister hook is attached to ctx for automatic LIFO cleanup.
    Rubik::Sandbox::Driver.register('firejail', FirejailDriver, ctx: ctx)
    puts '[Firejail] Registered driver into runtime'
  end
end

# When the plugin or context is disposed:
# ctx.dispose cleanly unregisters 'firejail' from Driver.registered_drivers
```

---

## 🚫 5. Forbidden Anti-Patterns

| Anti-Pattern | Description | Why It Fails |
| :--- | :--- | :--- |
| ❌ **Detached Cleanup Hooks** | Registering resources in `setup()` and cleanup in a remote `teardown()` function. | Violates locality of concern; teardown is easily skipped or out of sync with setup. |
| ❌ **Implicit Global Singletons** | Direct calls like `GlobalApp.get_service("db")` without declared dependencies. | Silently breaks when services depart or update at runtime; untyped and unverifiable. |
| ❌ **Leaked Side Effects** | Starting unmanaged background tasks (`Thread.new`, `set_interval`) outside `ctx`. | Leaves zombie listeners, memory leaks, and port conflicts upon module reload. |
| ❌ **Destructive Process Restarts** | Restarting the whole process for plugin/config updates. | Discards caches, active connections, and session memory; causes severe downtime for AI agents. |
| ❌ **Silent Failure Swallowing** | Catching initialization errors without running partial inverses. | Leaves corrupted, half-initialized state in the shared runtime environment. |

---

## 📋 6. Code Review & Generation Checklist

Before approving or deploying any dynamically composable component, verify:

- [ ] **Locality of Disposal:** Is every external side effect paired with an explicit inverse registered into `ctx`?
- [ ] **Explicit Dependencies:** Are all external services declared as coeffects rather than assumed globally?
- [ ] **LIFO Unwinding:** Will tearing down this module reverse effects in strict reverse chronological order?
- [ ] **Atomic Rollback on Error:** If the component throws an exception during initialization, does it cleanly revert all partial mutations?
- [ ] **Sub-Context Scoping:** Are child modules, experiments, or subagents scoped to a disposable sub-context (`ctx.extend()`)?
- [ ] **Zero-Restart Reloading:** Can this module be reloaded 1,000 times consecutively under load without leaking memory or leaving orphan listeners?

---

## 📚 7. Documentation i18n (Drift-Accepting)

Turkish translations live beside their sources as `X.tr.md` and are **allowed to lag** — the English document is the single source of truth:

- Every `X.tr.md` opens with a banner stating the English version is authoritative; keep that banner.
- `TOOLS.md` (generated by `rake tools:doc`) and `CHANGELOG.md` (append-only) are **not** translated.
- When a change edits `X.md`, update `X.tr.md` when the edit is cheap (typos, wording); skip it when structural. Divergence is legal — the banner covers it; never delete a translation to "fix" drift.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **rubik** (10410 symbols, 18009 relationships, 327 execution flows).

> Index stale? Run `node .gitnexus/run.cjs analyze --index-only` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? Bootstrap with `npx`, `bunx`, or `pnpm dlx` — e.g. `bunx gitnexus@latest analyze` (npm 11 npx crash; #1939).

## Always Do

- **MUST run impact before editing.** Use `impact({target: "symbolName", direction: "upstream"})` or `node .gitnexus/run.cjs impact "symbolName" --direction upstream --repo .`; report callers, processes, and risk. Never substitute grep for graph analysis.
- **MUST analyze graph changes before committing.** Use `detect_changes({scope: "all"})` (MCP) or `node .gitnexus/run.cjs detect-changes --scope all --repo .` (CLI fallback). `partial: true` or `truncated: true` is not a clean check — a zero means unseen, not unaffected; re-run it. For regression review: `detect_changes({scope: "compare", base_ref: "main"})` or `node .gitnexus/run.cjs detect-changes --scope compare --base-ref "main" --repo .`.
- MUST warn on HIGH/CRITICAL `risk` pre-edit; never use `riskSharedAxes` to waive a HIGH/CRITICAL `risk` warning. Compare File/symbol: MCP File omits axes; Graph-RAG expands File.
- **MUST treat `risk: UNKNOWN` as unresolved, not as low.** An empty caller set is not evidence the symbol is unused — it can also mean the callers are not resolvable by the index (plain-object property access, dynamic dispatch, cross-language calls). `impact` pairs `UNKNOWN` with a `riskNote` saying so. Confirm with a text search before treating the symbol as safe to change or delete; do not proceed on the strength of a zero.
- **MUST use `query({search_query: "concept"})` for concepts/flows, `context({name: "symbolName"})` for a named symbol, or `impact` for blast radius, on read-only callers, dependencies, imports, or execution flow.** Graph first; text search only for empty/`UNKNOWN`/literals.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method before MCP/CLI impact analysis.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis, and never read `UNKNOWN` as an all-clear — it means the walk could not answer, which is the one verdict that requires confirming by other means.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit before MCP/CLI graph change analysis.

## Resources

| Resource | Use for |
| --- | --- |
| `gitnexus://repo/rubik/context` | Codebase overview, check index freshness |
| `gitnexus://repo/rubik/clusters` | All functional areas |
| `gitnexus://repo/rubik/processes` | All execution flows |
| `gitnexus://repo/rubik/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
| --- | --- |
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
