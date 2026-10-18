# Rubik API — Embedding the Agent Runtime

Programmatic reference for hosting Rubik inside another Ruby program: wiring a
config, a tool registry, and an LLM provider, then driving the orchestrator
loop. All signatures below are verified against the source at the cited files.

## 1. Installation & require

```ruby
# Gemfile
gem "rubik"          # Gem name from rubik.gemspec; version follows the release.
```

```ruby
require "rubik"      # lib/rubik.rb requires the full stack: Config, LLM,
                     # Tools, Orchestrator, Runtime, Buffer, Security, Sandbox.
```

The gem root exposes only `Rubik::Error` (base class) and two deprecated
ambient accessors (`Rubik.runtime` — warns; use the context/`shell` coeffect
instead, see §4).

## 2. Minimal embedding example

Modeled on `test/support/scripted_agent_harness.rb` (the working reference
wiring). Replace `ScriptedProvider` with a real provider.

```ruby
require "rubik"

root_dir = File.expand_path("~/my-agent-workspace")

# Config: defaults deep-merged with global + project YAML.
config = Rubik::Config.new(root_dir: root_dir)
config.set("models.default", { "provider" => "ollama", "name" => "qwen3.5:9b" })
spec = config.model_spec(:default)   # => {"provider"=>..., "name"=>..., "endpoint"=>...}

# Buffer: in-memory edits over the workspace, applied to disk atomically.
buffer_manager = Rubik::Buffer::Manager.new(root_dir: root_dir)
context_index  = Rubik::Context::Index.new(root_dir: root_dir)

# Toolbelt: built-in tools. Service kwargs resolve explicitly; anything you
# omit falls back to a fail-closed fresh default (Tools::Services FRESH table).
registry = Rubik::Tools::Registry.build_default(
  buffer_manager:   buffer_manager,
  context_index:    context_index,
  ast_graph:        Rubik::AST::Graph.new,
  adapter_registry: Rubik::Adapter::Registry.new,
  guard:            Rubik::Security::Guard.new,
  sandbox_runner:   Rubik::Sandbox::Runner.new(root_dir: root_dir),
  root_dir:         root_dir
)

# Provider contract (lib/rubik/llm/provider.rb): implement #complete OR
# #stream_chat — each derives the other. A blocking provider returns an
# LLM::Response; tool calls may ride `tool_calls:` (native) or be encoded in
# `text` as `{"tool": name, "args": {...}}` JSON (bare or ```json-fenced),
# which the loop parses (Loop#parse_tool_call).
class ScriptedProvider < Rubik::LLM::BaseProvider
  def initialize(responses)
    super()
    @responses = responses.dup
  end

  def complete(_messages, _opts = {})
    text = @responses.shift || '{"tool": "finish", "args": {"message": "done"}}'
    Rubik::LLM::Response.new(text: text)
  end
end

# Shell: the minimal facade the loop reads collaborators from. All six slots
# may be nil except what your tools/flow need (harness passes nil for three).
Shell = Struct.new(:buffer_manager, :snapshot_store, :context_index,
                   :lsp_manager, :config, :runtime_manager)
shell = Shell.new(buffer_manager, nil, context_index, nil, config, nil)

agent = Rubik::Orchestrator::Loop.new(
  provider:      ScriptedProvider.new(['{"tool": "write_file", "args": {"path": "notes.txt", "content": "hi"}}']),
  tool_registry: registry,
  shell:         shell,
  max_steps:     25
)

result = agent.run("Create notes.txt saying hi")
result[:ok]      # => true
result[:steps]   # => 2 (loop.rb#turn_result: {ok:, steps:, tokens:, streamed:, loop_instance:})
result[:tokens]  # => {input: 0, output: 0}
result[:output]  # final assistant text (present on success)

# Edits land in the buffer; flush to disk when satisfied.
buffer_manager.apply! if buffer_manager.dirty?
```

`Loop#run` signature: `run(task_prompt, model: nil, plan_only: false,
goal_mode: false, initial_context: nil, conversation_history: [])`
(lib/rubik/orchestrator/loop.rb:102). It returns the result hash above —
`:error` (string) replaces `:output` on failure.

## 3. Core objects

| Object | Responsibility | Key methods |
| :--- | :--- | :--- |
| `Rubik::Config` | Merged config store + model roles | `new(root_dir:, home_dir: nil)`, `fetch(key, default=nil)`, `set(key, value, persist: nil)` (→ `{ok:…}` outcome hash), `on_change(prefix = nil, &block)` (→ unsubscribe proc), `model_spec(role = :default)`; `ModelCatalog`: `upsert_provider_model(provider, model, context_limit:, persist: nil)`, `remove_provider_model`, `provider_spec` |
| `Rubik::LLM::Registry` | Provider instances + model catalog | `new(config = nil)`, `register(name, provider)`, `get(name)`, `get_for(spec)`, `list`, `catalog`, `context_limit_for`, `max_output_tokens_for` |
| `Rubik::LLM::Router` | Role → provider resolution | `new(config:, registry: nil)`, `route(task_type: :auto, prompt: "")` → `{provider:, model:, role:, spec:, context_limit:, max_output_tokens:}`, `stream_chat(messages, …, &block)` |
| `Rubik::LLM::BaseProvider` | Provider contract | implement `#complete(messages, opts = {})` → `LLM::Response` or `#stream_chat` yielding `LLM::Chunk` (`done: true` terminator); `estimate_tokens` |
| `Rubik::Tools::Registry` | Toolbelt + schemas | `Registry.build_default(buffer_manager:, root_dir:, …)` — service override slots: `guard, context_index, adapter_registry, ast_graph, task_manager, sandbox_runner, subagent_supervisor, dmesg` (unknown kwargs raise `ArgumentError`); `register(tool, aliases: [], origin:)`, `get`, `list`, `schemas` (coeffect-gated), `swap`, `unregister` |
| `Rubik::Buffer::Manager` | Buffered edits, atomic apply | `new(root_dir:, …)`, `write(path, content, reset_baseline: false)`, `dirty?(path = nil)`, `apply!(target_paths = nil, policy: nil)` (baseline-hash conflict check; `policy: "overwrite"`), `last_conflicts`, `diff_all`, `add_root(path, rw: false)` |
| `Rubik::Runtime::Context` | Coeffects + revertible effects | see §4 |
| `Rubik::Runtime::Manager` | Reactive component lifecycle | `new(context = nil)`, `register_component(name, inject: [], requires: [], provides: [], config: {}, &factory)`, `provide`/`unprovide` (reactive), `reconcile_all(changed_service: nil)`, `swap_component`, `dispose!` |
| `Rubik::Orchestrator::Loop` | The agent loop | `initialize(provider:, tool_registry:, shell:, max_steps:)` (also `warn_at_ratio:`, `model:`, `on_step:`, `context_limit:`, `max_output_tokens:`), `run(task_prompt, …)` → result hash |

`ComponentFiber` states: `[:unloaded, :pending, :active, :failed, :disposed]`
(lib/rubik/runtime/fiber.rb:46). Factory is called as `factory.call(sub_context, config)`.

## 4. The Context protocol (brief)

`Rubik::Runtime::Context` implements the AGENTS.md contract: **revertible
effects** (§1.A) — every side effect registers its inverse via
`on_dispose`/`register_disposable`, and `dispose` unwinds them in strict LIFO
order; **coeffects** (§1.B) — dependencies are declared and resolved through
`provide`/`require` over an explicit context chain (canonical keys in
`Rubik::Coeffects`, legacy aliases resolved transparently), never via ambient
singletons. `provide` keeps exactly one delete-inverse per key (re-providing
swaps the value; `unprovide` retracts symmetrically), `extend` scopes a child
context that is disposed with its parent, and a failing inverse is
error-isolated: it is recorded (see `last_dispose_errors`) without aborting
the drain (§5). Raising a factory mid-activation rolls its partial inverses
back atomically (§2 — fiber `Active → Failed`).

Host-side reactive wiring:

```ruby
manager = Rubik::Runtime::Manager.new
manager.register_component("cache", inject: ["config"], provides: []) do |ctx, cfg|
  svc = CacheService.new(ctx.require("config"))
  ctx.on_dispose { svc.shutdown }    # inverse-by-construction
  svc
end
manager.provide("config", config)    # reactive: activates pending fibers
manager.dispose!                     # full LIFO unwind
```

## 5. Error contracts

| Error | Raised by | Meaning |
| :--- | :--- | :--- |
| `Rubik::Error` | gem root | Base class for Rubik errors |
| `Rubik::LLM::ClientError` | providers/HTTP client (llm/client.rb) | Provider request failed; `RateLimitError < ClientError` adds `retry_after` |
| `Rubik::Buffer::InvalidPathError` | `Buffer::Manager#sanitize_path`/`write` | Path outside root/additional roots/allowed dirs (traversal blocked) |
| `Rubik::Runtime::CoeffectMissingError` | `Context#require` | Declared coeffect unsatisfied on the whole context chain |
| `Rubik::Runtime::ContextDisposedError` | `Context#extend` | Extending a disposed context (fail fast — no fallback) |

Provider `ClientError`s are recovered inside the loop (retry/switch); only
contract violations surface to the host.

## 6. Where to go next

- [Testing guide](../development/testing.md) — the scripted harness this
  document's example is modeled on.
- [Configuration guide](../how-to/configuration.md) — config files, scopes,
  model roles, and provider specs.
- [Built-in tool catalog](../../TOOLS.md) — tools, schemas, and custom tools.
- [Architecture](../explanation/architecture.md) and
  [plugin guide](../how-to/plugins.md) — runtime internals and plugin hosting.
- [Security practices](../../SECURITY.md) — command checks, workspace
  boundaries, and sandbox behavior.

---

See the [documentation index](../index.md) or return to the [README](../../README.md).
