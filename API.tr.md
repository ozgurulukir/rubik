# Rubik API — Ajan Runtime'ını Gömme

> Bu belge, [`API.md`](API.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

Rubik'i başka bir Ruby programı içinde barındırmaya yönelik programatik
başvuru: bir config, bir tool registry ve bir LLM sağlayıcı bağlanır, ardından
orkestratör döngüsü sürülür. Aşağıdaki tüm imzalar, atıf yapılan dosyalardaki
kaynak kodla doğrulanmıştır.

## 1. Kurulum ve require

```ruby
# Gemfile
gem "rubik"          # gemspec: spec.name = "rubik", version 0.1.0
```

```ruby
require "rubik"      # lib/rubik.rb requires the full stack: Config, LLM,
                     # Tools, Orchestrator, Runtime, Buffer, Security, Sandbox.
```

Gem kökü yalnızca `Rubik::Error` (temel sınıf) ile kullanımdan kaldırılmış iki
ambient erişimciyi (`Rubik.runtime` — uyarı verir; bunun yerine
context/`shell` coeffect'ini kullanın, bkz. §4) ortaya çıkarır.

## 2. Minimal Gömme Örneği

`test/support/scripted_agent_harness.rb` üzerinde modellenmiştir (çalışan
referans bağlantı şeması). `ScriptedProvider` yerine gerçek bir sağlayıcıyla
değiştirin.

```ruby
require "rubik"

root_dir = File.expand_path("~/my-agent-workspace")

# Config: defaults deep-merged with global + project YAML.
config = Rubik::Config.new(root_dir: root_dir)
config.set("models.default", { "provider" => "ollama", "name" => "qwen2.5-coder:7b" })
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

`Loop#run` imzası: `run(task_prompt, model: nil, plan_only: false,
goal_mode: false, initial_context: nil, conversation_history: [])`
(lib/rubik/orchestrator/loop.rb:102). Yukarıdaki sonuç hash'ini döndürür —
hata durumunda `:output` yerine `:error` (string) döner.

## 3. Çekirdek Nesneler

| Nesne | Sorumluluk | Önemli metotlar |
| :--- | :--- | :--- |
| `Rubik::Config` | Birleştirilmiş config deposu + model rolleri | `new(root_dir:, home_dir: nil)`, `fetch(key, default=nil)`, `set(key, value, persist: nil)` (→ `{ok:…}` sonuç hash'i), `on_change(prefix = nil, &block)` (→ abonelikten çıkma proc'u), `model_spec(role = :default)`; `ModelCatalog`: `upsert_provider_model(provider, model, context_limit:, persist: nil)`, `remove_provider_model`, `provider_spec` |
| `Rubik::LLM::Registry` | Sağlayıcı örnekleri + model kataloğu | `new(config = nil)`, `register(name, provider)`, `get(name)`, `get_for(spec)`, `list`, `catalog`, `context_limit_for`, `max_output_tokens_for` |
| `Rubik::LLM::Router` | Rol → sağlayıcı çözümlemesi | `new(config:, registry: nil)`, `route(task_type: :auto, prompt: "")` → `{provider:, model:, role:, spec:, context_limit:, max_output_tokens:}`, `stream_chat(messages, …, &block)` |
| `Rubik::LLM::BaseProvider` | Sağlayıcı sözleşmesi | `#complete(messages, opts = {})` → `LLM::Response` veya `LLM::Chunk` üreten `#stream_chat` (`done: true` sonlandırıcısı) implement edilir; `estimate_tokens` |
| `Rubik::Tools::Registry` | Toolbelt + şemalar | `Registry.build_default(buffer_manager:, root_dir:, …)` — servis override slot'ları: `guard, context_index, adapter_registry, ast_graph, task_manager, sandbox_runner, subagent_supervisor, dmesg` (bilinmeyen kwargs `ArgumentError` fırlatır); `register(tool, aliases: [], origin:)`, `get`, `list`, `schemas` (coeffect koşullu), `swap`, `unregister` |
| `Rubik::Buffer::Manager` | Tamponlanmış düzenlemeler, atomik apply | `new(root_dir:, …)`, `write(path, content, reset_baseline: false)`, `dirty?(path = nil)`, `apply!(target_paths = nil, policy: nil)` (baseline-hash çakışma denetimi; `policy: "overwrite"`), `last_conflicts`, `diff_all`, `add_root(path, rw: false)` |
| `Rubik::Runtime::Context` | Coeffect'ler + geri döndürülebilir etkiler | bkz. §4 |
| `Rubik::Runtime::Manager` | Reaktif bileşen yaşam döngüsü | `new(context = nil)`, `register_component(name, inject: [], requires: [], provides: [], config: {}, &factory)`, `provide`/`unprovide` (reaktif), `reconcile_all(changed_service: nil)`, `swap_component`, `dispose!` |
| `Rubik::Orchestrator::Loop` | Ajan döngüsü | `initialize(provider:, tool_registry:, shell:, max_steps:)` (ayrıca `warn_at_ratio:`, `model:`, `on_step:`, `context_limit:`, `max_output_tokens:`), `run(task_prompt, …)` → sonuç hash'i |

`ComponentFiber` durumları: `[:unloaded, :pending, :active, :failed, :disposed]`
(lib/rubik/runtime/fiber.rb:46). Factory, `factory.call(sub_context, config)`
şeklinde çağrılır.

## 4. Context Protokolü (kısaca)

`Rubik::Runtime::Context`, AGENTS.md sözleşmesini uygular: **geri
döndürülebilir etkiler** (revertible effects, §1.A) — her yan etki tersini
`on_dispose`/`register_disposable` aracılığıyla kaydeder ve `dispose`, bunları
katı LIFO sırasıyla geri sarar; **coeffect'ler** (§1.B) — bağımlılıklar, açık
bir context zinciri üzerinden `provide`/`require` ile bildirilip çözümlenir
(kanonik anahtarlar `Rubik::Coeffects` içinde, legacy takma adlar saydamca
çözülür), asla ambient singleton'lar üzerinden değil. `provide`, anahtar
başına tam olarak bir silme-tersi tutar (yeniden provide etmek değeri
değiştirir; `unprovide` simetrik biçimde geri çeker), `extend`, ebeveyniyle
birlikte dispose edilen bir alt context'i kapsama alır ve başarısız bir ters
işlem hata-izolelidir: drenajı yarıda kesmeden kayda geçirilir (bkz.
`last_dispose_errors`, §5). Aktivasyon ortasında hata fırlatan bir factory,
kısmi ters işlemlerini atomik olarak geri alır (§2 — fiber `Active → Failed`).

Host tarafındaki reaktif bağlantı şeması:

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

## 5. Hata Sözleşmeleri

| Hata | Fırlatan | Anlam |
| :--- | :--- | :--- |
| `Rubik::Error` | gem kökü | Rubik hataları için temel sınıf |
| `Rubik::LLM::ClientError` | sağlayıcılar/HTTP istemcisi (llm/client.rb) | Sağlayıcı isteği başarısız; `RateLimitError < ClientError` `retry_after` ekler |
| `Rubik::Buffer::InvalidPathError` | `Buffer::Manager#sanitize_path`/`write` | Kök/ek kök dizinler/izinli dizinler dışında kalan yol (traversal engellenir) |
| `Rubik::Runtime::CoeffectMissingError` | `Context#require` | Bildirilen coeffect, tüm context zincirinde karşılanmıyor |
| `Rubik::Runtime::ContextDisposedError` | `Context#extend` | Dispose edilmiş bir context'in extend edilmesi (fail fast — fallback yok) |

Sağlayıcı `ClientError`'ları döngü içinde kurtarılır (retry/switch); yalnızca
sözleşme ihlalleri host'a yansır.

## 6. Sonraki Adımlar

- `TESTING.md` — bu belgedeki örneğin modellendiği scripted harness.
- `CONFIG.md` — config dosyaları, kapsamlar, model rolleri, provider spec'leri.
- `TOOLS.md` — yerleşik tool'lar, şemalar, özel tool yazımı.
- `ARCHITECTURE.md`, `PLUGINS.md` — runtime iç yapısı ve plugin barındırma.
- `SECURITY.md` (doğrulayın — yazıldığı sırada repo kökünde mevcut değildi).
