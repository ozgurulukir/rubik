# Plan 89 — Crystal Adaptörü, Çok Dilli Generic Test Koşucusu ve JIT Self-Healing Çalışma Zamanı

> **Durum:** 🟢 Tamamlandı  
> **Zorluk:** Orta  
> **Faz:** 8  
> **Öneri Bölümü:** Çok Dilli Çalışma Zamanı (Multilingual Runtime) & Kendi Kendini Onarma (Self-Healing)  
> **İlgili Planlar:** [07](07-dil-adaptor-cercevesi.md), [15](15-benchmark-kabul-testleri.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [76](76-lsp-buffer-jit-senkronizasyonu-oturum-arac-kaydi-ve-modern-web-adaptoru.md), [88](88-tampon-cakisma-deadlock-cozumu-ve-apply-buffer-guclendirmesi.md)

---

## 🎯 Motivasyon ve Gözlemlenen Sorun

`fff.cr` oturumunda model projenin testlerini çalıştırmak için `run_tests` aracını çağırdığında şu hata ile karşılaşmıştır:
```text
run_tests — crystal
⎿ ✖ No adapter available for language 'crystal'. Check the language name or configure a test runner via repair_runtime_service.
```

Bu olayın derinlemesine analizinde üç temel mimari eksiklik tespit edilmiştir:
1. **Yerleşik Crystal Desteğinin Yokluğu:** Rubik; Ruby, Python, Go, Rust, C, Zig ve Node/TS dillerini yerleşik adaptörlerle (`lib/rubik/adapter/`) desteklerken, modern sistem dillerinden biri olan **Crystal** için yerleşik bir adaptör ve `Discovery` işaretçisi bulunmamaktadır.
2. **`repair_runtime_service` Adaptör Boşluğu:** Model hatada önerilen `repair_runtime_service(target: "test_runner", language_or_type: "crystal", proposed_command: "crystal spec")` çağrısını yapsa bile, `RepairRuntimeTool` yalnızca önceden var olan adaptörlerin `custom_test_cmd` alanını günceller. Eğer `Adapter::Registry` içinde o dil kayıtlı değilse dinamik bir adaptör oluşturmaz; dolayısıyla sonraki `run_tests` çağrısı yine aynı hatayı verir.
3. **Sıfır Yapılandırmalı (JIT) Kendi Kendini Onarma Eksikliği:** Çalışma alanında `shard.yml` gibi bilinen bir proje dosyası varken ve sistemde `crystal` binary'si bulunuyorken, `run_tests` aracının hata vermek yerine projeyi anlayıp testleri doğrudan çalıştırabilmesi (JIT adaptör sentezi) gerekir.

Bu plan, hem Crystal dilini birinci sınıf vatandaş olarak Rubik ekosistemine katar hem de daha önce hiç tanımlanmamış diller (Elixir, Haskell, Dart, Nim, Kotlin vb.) için dinamik `GenericAdapter` sentezi ve JIT self-healing yeteneği kazandırır.

---

## 🔬 GitNexus Etki Analizi Özeti

| Sembol | Risk | Etki |
|:---|:---:|:---|
| `Rubik::Tools::RunTestsTool` | LOW | 11 downstream çağrı (builtins.rb, test süiti) |
| `Rubik::Tools::RepairRuntimeTool` | LOW | 11 downstream çağrı (builtins.rb, test süiti) |
| `Rubik::Adapter::Registry` | LOW | 23 downstream çağrı (shell, runtime manager, testler) |
| `Rubik::Runtime::Discovery` | LOW | Dil adayları, test runner ve formatter keşfi |

---

## 📐 Çözüm Mimarisi

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1. Yerleşik Crystal Adaptörü (CrystalAdapter < BaseAdapter)                 │
│    - Test: `crystal spec` (shard.yml / shard.lock algılama)                 │
│    - Format: `crystal tool format`                                          │
│    - Syntax / Compiler: `crystal build --no-codegen`                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 2. Çok Dilli GenericAdapter (Dinamik Adaptör Sentezi)                      │
│    - Bilinmeyen diller için dinamik komut bağlama (test, format, syntax)    │
│    - BaseAdapter arayüzü ile %100 uyumluluk (ProcessRunner & Diagnostic)    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 3. JIT Self-Healing & RepairRuntimeTool Dinamik Kaydı                      │
│    - RunTestsTool: Adaptör yoksa Discovery & Config üzerinden JIT Generic   │
│      Adapter üretip kaydeder; testi koşturur (Model hata görmez).           │
│    - RepairRuntimeTool: `test_runner` veya `linter` tamirinde yeni dil ise │
│      anında GenericAdapter sentezleyip Registry'ye ve Context'e kaydeder.   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ 4. Elm Tarzı Eyleme Dönüştürülebilir Hata Mesajı                            │
│    - Keşif başarısız olursa kopyalanabilir repair ve run_command şablonu    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Uygulama Adımları

### D-1: Yerleşik `CrystalAdapter`
**Dosyalar:** `lib/rubik/adapter/crystal.rb`, `lib/rubik/adapter.rb`, `lib/rubik/adapter/registry.rb`

1. `Rubik::Adapter::CrystalAdapter < BaseAdapter` sınıfı:
   - `initialize`: `super("crystal", "crystal")`
   - `check_syntax(file_path)`: `crystal build --no-codegen #{file_path}`
   - `compile(root_dir)`: `shards build` (varsa) veya `crystal build`
   - `default_test_cmd(root_dir)`: `crystal spec`
   - `default_format_cmd`: `crystal tool format`
2. `lib/rubik/adapter/registry.rb` içine `"crystal" => CrystalAdapter.new` eklenmesi.
3. `lib/rubik/runtime/discovery.rb` içine:
   - `TEST_RUNNER_MARKERS["crystal"] = [{ marker: "shard.yml", candidates: ["crystal spec"] }, { marker: "shard.lock", candidates: ["crystal spec"] }]`
   - `DEFAULT_TEST_RUNNERS["crystal"] = "crystal spec"`
   - `FORMATTER_CANDIDATES["crystal"] = ["crystal tool format"]`
   - `LSP_CANDIDATES["crystal"] = ["crystalline"]` (mevcut olan korunur).

---

### D-2: Dinamik `GenericAdapter`
**Dosya:** `lib/rubik/adapter/generic.rb`

Bilinmeyen herhangi bir dil veya özel komut kümesi için genel amaçlı adaptör:
```ruby
module Rubik
  module Adapter
    class GenericAdapter < BaseAdapter
      attr_accessor :custom_syntax_cmd

      def initialize(name, binary_name: nil, test_cmd: nil, format_cmd: nil, syntax_cmd: nil)
        super(name, binary_name || (test_cmd ? test_cmd.split.first : name))
        @custom_test_cmd = test_cmd
        @custom_format_cmd = format_cmd
        @custom_syntax_cmd = syntax_cmd
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        return { ok: true, output: "Syntax check not configured for #{@name}" } unless @custom_syntax_cmd

        cmd = "#{@custom_syntax_cmd} #{Shellwords.escape(file_path)}"
        ProcessRunner.run(cmd)
      end
    end
  end
end
```

---

### D-3: `RepairRuntimeTool` ile Dinamik Adaptör Sentezi
**Dosya:** `lib/rubik/tools/builtins/lifecycle.rb`

`target == "test_runner"` ve `target == "linter"` bloklarında, eğer `@adapter_registry.get(lang)` `nil` ise:
```ruby
when "test_runner"
  @config&.set("test.runners.#{lang}", proposed_cmd, persist: :project)
  if @adapter_registry
    adapter = @adapter_registry.get(lang)
    if adapter
      adapter.custom_test_cmd = proposed_cmd
    else
      # Dinamik adaptör sentezlenip Registry'ye kaydedilir
      new_adapter = Rubik::Adapter::GenericAdapter.new(lang, test_cmd: proposed_cmd)
      new_adapter.config = @config
      @adapter_registry.register(lang, new_adapter)
    end
  end
  root_ctx.provide("runner:#{lang}", proposed_cmd)
```
Aynı dinamik üretim `linter` için de uygulanır.

---

### D-4: `RunTestsTool` JIT Self-Healing & Yönlendirici Hata Mesajı
**Dosya:** `lib/rubik/tools/builtins/exec.rb`

`RunTestsTool#execute` içinde adaptör bulunamadığında (`adapter.nil?`):
1. **Config Kontrolü:** `@config&.fetch("test.runners.#{lang}")` varsa dinamik `GenericAdapter` oluşturulup test koşturulur.
2. **Otomatik Keşif:** `Runtime::Discovery.test_runner_candidates(lang, root_dir: @root_dir, config: @config)` çalıştırılır. İlk çalışan aday sistemde mevcutsa (`Discovery.binary_available?`), otomatik olarak bir `GenericAdapter` yaratılıp registry'ye kaydedilir ve test doğrudan çalıştırılır.
3. **Elm Tarzı Hata Çıktısı:** Eğer hiçbir komut bulunamazsa modelin doğrudan çalıştırabileceği net ve kopyalanabilir hata döndürülür:
```text
-- NO TEST ADAPTER CONFIGURED ---------------------------------------
No test runner is configured for language '#{lang}'.

To configure a test runner automatically, call:
  repair_runtime_service(target: "test_runner", language_or_type: "#{lang}", proposed_command: "<command>")

Or execute your test command directly via:
  run_command(command: "<command>")
```

---

### D-5: Test Kapsamı ve Doğrulama
**Yeni Test Dosyası:** `test/unit/test_crystal_and_generic_adapter.rb`

1. **CrystalAdapter Birim Testleri:** `available?`, `resolve_test_cmd`, `compile`, `check_syntax`.
2. **GenericAdapter Birim Testleri:** Dinamik komut bağlama ve çalıştırma.
3. **RepairRuntimeTool Sentez Testi:** Tanımlanmamış bir dilde (`elixir`, `dart`, `crystal`) `repair_runtime_service` çağrıldığında `GenericAdapter`'ın otomatik oluşturulup registry'ye kaydedildiğinin doğrulanması.
4. **RunTestsTool JIT Self-Healing Testi:** Adaptörsüz bir projede test işaretçisi varken `run_tests` çağrıldığında otomatik adaptör sentezlenip testin çalıştığının doğrulanması.
5. **Mevcut Test Paketi:** `rake test` (1480+ test) ve `rubocop` 0 offense.

---

## 🧪 Kırmızı Çizgiler

- `test_module_hygiene.rb` kuralları: `config/defaults.rb < 200`, `builtins/*.rb < 400`, `orchestrator/*.rb < 400`.
- `test_repl_command_decoupling.rb`: `shell.rb <= 700`.
- Tüm değişiklikler geriye dönük uyumlu kalmalıdır.
- RuboCop 0 offense korunmalıdır.

---

## 🗂️ Etkilenen Dosyalar

| Dosya | Değişiklik Türü |
|:------|:----------------|
| `lib/rubik/adapter/crystal.rb` | D-1: Yeni yerleşik Crystal adaptörü |
| `lib/rubik/adapter/generic.rb` | D-2: Çok dilli dinamik generic adaptör |
| `lib/rubik/adapter.rb` | D-1, D-2: Require tanımları |
| `lib/rubik/adapter/registry.rb` | D-1: Crystal adaptörü kaydı |
| `lib/rubik/runtime/discovery.rb` | D-1: Crystal test & format işaretçileri |
| `lib/rubik/tools/builtins/lifecycle.rb` | D-3: `RepairRuntimeTool` dinamik adaptör sentezi |
| `lib/rubik/tools/builtins/exec.rb` | D-4: `RunTestsTool` JIT self-healing & Elm rehberliği |
| `lib/rubik/tools/registry.rb` | D-4: `RunTestsTool` konfigürasyon enjeksiyonu |
| `test/unit/test_crystal_and_generic_adapter.rb` | D-5: Yeni birim testleri |

---

## 📝 Uygulama Günlüğü

### 2026-09-11 — Plan 89 Tamamlandı
- **D-1 (CrystalAdapter):** `lib/rubik/adapter/crystal.rb` oluşturuldu (`crystal build --no-codegen`, `shards build` / `crystal build`, `crystal spec`, `crystal tool format`). `lib/rubik/adapter.rb` ve `lib/rubik/adapter/registry.rb` içine entegre edildi. `lib/rubik/runtime/discovery.rb` içine test ve formatter işaretçileri eklendi.
- **D-2 (GenericAdapter):** `lib/rubik/adapter/generic.rb` ile bilinmeyen diller veya özel komutlar için dinamik adaptör sentezi yazıldı.
- **D-3 (RepairRuntimeTool):** `lib/rubik/tools/builtins/lifecycle.rb` içinde `test_runner` veya `linter` tamirinde adaptörsüz diller için otomatik `GenericAdapter` sentezlenip canlı registry ve context'e bağlandı.
- **D-4 (RunTestsTool):** `lib/rubik/tools/builtins/exec.rb` içinde adaptör bulunamadığında önce config ve keşif adaylarından JIT `GenericAdapter` sentezlenmesi sağlandı; aday bulunamazsa kopyalanabilir ve rehberlik edici Elm tarzı hata mesajı dönüldü.
- **D-5 (Testler & Doğrulama):** `test/unit/test_crystal_and_generic_adapter.rb` (16 test, 77 assertion) eklendi; boş/boşluklu dil argümanı ve mevcut adaptör konfigürasyon güncellemesi uç senaryoları doğrulandı. Tam süit `1496 runs, 8895 assertions, 0 failures, 0 errors, 2 skips` ile %100 yeşil; RuboCop 0 offense ile doğrulandı. GitNexus `detect_changes` analizi temiz (risk: LOW).

