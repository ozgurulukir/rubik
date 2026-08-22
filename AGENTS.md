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
- **Monoidal Accumulator ($\Omega$):** All effects generated within a component's lifecycle are tracked in a scoped accumulator $\Omega$. Upon component removal or reload, accumulated inverses are executed in strict reverse chronological order (LIFO).
- **Soundness of Rollback ($A(\sigma) \sim \sigma_0$):** Reverting a component must restore the context to an observational state equivalent to before the component was applied.
- **Failure Reversibility:** If activation fails midway, the partial inverse accumulator must execute immediately to restore the environment to its exact prior state.

### B. Spatial Composability (Reactive Coeffects)
- **Explicit Coeffect Specifications:** Components must never query untyped global registries or ambient singletons. Required capabilities/services must be declared explicitly as typed coeffect dependencies ($\Sigma \vdash C : \tau$).
- **Reactive State Transitions:** When the environment context changes (a service is registered, updated, or unregistered), the runtime classifies the transition for each dependent component:
  - **`Activating`**: Coeffects newly satisfied $\implies$ transition component from `Pending` to `Active`.
  - **`Deactivating`**: Required coeffects lost $\implies$ gracefully unwind and transition component from `Active` to `Pending`.
  - **`Neutral`**: Irrelevant change $\implies$ no lifecycle perturbation.

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
| **`Pending`** | Coeffects Satisfied | **`Active`** | Instantiate fiber, track effect inverses in accumulator $\Omega$. |
| **`Active`** | Coeffects Lost | **`Pending`** | Execute $\Omega$ in LIFO order; preserve persistent state. |
| **`Active`** | Error during activation | **`Failed`** | Execute partial $\Omega$; report failure; restore prior state. |
| **`*`** | Explicit Unload | **`Disposed`** | Full unwind of $\Omega$; remove fiber from registry. |

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

## 💻 4. Implementation Reference Patterns

### A. TypeScript Pattern (Cordis Canonical Standard)

```typescript
import { Context, Service } from 'cordis';

// 1. Declare Service Interface (Coeffect/Effect contract)
export interface DatabaseService {
  query<T = any>(sql: string, params?: any[]): Promise<T[]>;
}

export const Database = Service.extend<DatabaseService>('database');

// 2. Component Implementation with Explicit Context
export interface AnalyticsConfig {
  endpoint: string;
  heartbeatIntervalMs?: number;
}

export const AnalyticsPlugin = {
  name: 'analytics-plugin',
  // Declare required coeffects (Spatial Composability)
  inject: ['database', 'httpServer'],

  apply(ctx: Context, config: AnalyticsConfig) {
    // Guaranteed to run ONLY when 'database' and 'httpServer' are both ACTIVE
    const db = ctx.get<DatabaseService>('database');
    const interval = config.heartbeatIntervalMs ?? 5000;

    // A. Revertible HTTP Route Registration
    ctx.httpServer.get('/api/analytics', async () => {
      return await db.query('SELECT * FROM metrics ORDER BY timestamp DESC LIMIT 50');
    });

    // B. Revertible Timer (Inverse paired immediately)
    const timer = setInterval(() => {
      console.log('[Analytics] Heartbeat check...');
    }, interval);

    // Register cleanup callback directly into the fiber's accumulator
    ctx.on('dispose', () => {
      clearInterval(timer);
      console.log('[Analytics] Timer cleared cleanly');
    });
  }
};
```

---

### B. Python Pattern (Context & RAII Disposable Stack)

```python
from typing import Callable, Any, Dict, List, Optional
from contextlib import ExitStack

class Context:
    """Unified context managing both effects (inverses) and coeffects (services)."""
    
    def __init__(self, parent: Optional['Context'] = None):
        self.parent = parent
        self._stack = ExitStack()
        self._services: Dict[str, Any] = {}
        self._disposables: List[Callable[[], None]] = []

    def register_disposable(self, cleanup_fn: Callable[[], None]) -> None:
        """Tracks revertible effect inverse in LIFO order (Temporal Composability)."""
        self._stack.callback(cleanup_fn)

    def provide(self, name: str, service: Any) -> None:
        """Registers a service into the context with automatic inverse tracking."""
        self._services[name] = service
        self.register_disposable(lambda: self._services.pop(name, None))

    def require(self, name: str) -> Any:
        """Resolves a coeffect dependency (Spatial Composability)."""
        if name in self._services:
            return self._services[name]
        if self.parent:
            return self.parent.require(name)
        raise RuntimeError(f"Required coeffect '{name}' is not satisfied in the context.")

    def extend(self) -> 'Context':
        """Creates a scoped child context."""
        return Context(parent=self)

    def dispose(self) -> None:
        """Unwinds all accumulated effects cleanly in reverse order."""
        self._stack.close()


# Example Component Usage
def apply_metrics_collector(ctx: Context, db_service_name: str = "database"):
    # Coeffect resolution
    db = ctx.require(db_service_name)
    
    # Revertible Resource
    active_socket = open_telemetry_socket()
    ctx.register_disposable(lambda: active_socket.close())
```

---

## 🚫 5. Forbidden Anti-Patterns

| Anti-Pattern | Description | Why It Fails |
| :--- | :--- | :--- |
| ❌ **Detached Cleanup Hooks** | Registering resources in `setup()` and cleanup in a remote `teardown()` function. | Violates locality of concern; teardown is easily skipped or out of sync with setup. |
| ❌ **Implicit Global Singletons** | Direct calls like `GlobalApp.getService("db")` without declared dependencies. | Silently breaks when services depart or update at runtime; untyped and unverifiable. |
| ❌ **Leaked Side Effects** | Starting unmanaged background tasks (`setInterval`, threads) outside `ctx`. | Leaves zombie listeners, memory leaks, and port conflicts upon module reload. |
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
