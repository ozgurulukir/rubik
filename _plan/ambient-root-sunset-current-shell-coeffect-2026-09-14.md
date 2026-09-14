# 📋 Plan: Ambient Kök Geri Sayımı — `Rubik.current_shell` → `shell` Coeffect

> **Kaynak:** [`_reviews/2026-09-14-architectural-review.md`](../_reviews/2026-09-14-architectural-review.md) — **Öneri 4** ("Küresel durum için geri sayım") + **Bulgu 3** (tek ambient kök)
> **Tarih:** 14 Eylül 2026 (Pzt)
> **Durum:** 🟡 Planlandı — uygulama bekliyor
> **Öncül planlar:** [20](20-spatiotemporal-composability-eklenti-dongusu.md) (runtime döngüsü), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md) (coeffect dönüşümü), [33](33-spatiotemporal-coeffect-inverses-ve-runtime-gorsellestirme.md) (inverses), Öneri 3 planı ([loop-provider-resolver-and-pr-checklist-2026-09-14.md](loop-provider-resolver-and-pr-checklist-2026-09-14.md) — PR kontrol listesi)

---

## 🎯 Hedef

Review Bulgu 3'ün konusu `Rubik.current_shell` / `Rubik.runtime_manager`, kod tabanındaki **tek ambient köküdür** (4 satır: yayın `warm_up!`'ta, temizlik identity-kontrollü `stop`'ta). Review'in önerisi: okuyan her çağrı noktasını `ctx.require("shell")`'e çevirmek. **Keşif bu öneriyi şekillendirdi:** kod tabanı içinde ambient *okuyucu yok* — `shell` coeffect'i `wire_runtime_context` içinde **zaten sağlanıyor**. Dolayısıyla Öneri 4'ün gerçek işi üç tek-amaçlı iş paketidir:

1. **İş Paketi A — SSOT ilanı:** `shell` anahtarını `Rubik::Coeffects` SSOT'unda kanonik coeffect anahtarı olarak ilan et (bugün sessizce sağlanıyor ama SSOT'ta listelenmiyor — üçüncü taraf keşfedemez, review'in "ctx.require("shell")" hedefi dokümante edilmiyor).
2. **İş Paketi B — Ambient geri sayım:** tek okuyucuyu (`Rubik.runtime` — yalnızca bir test kullanıyor) deprekasyon köprüsüne çevir; okuma yüzeyini kapatmaya başla, davranışı koru.
3. **İş Paketi C — Koruma testleri:** (a) `lib/` içinde yeni ambient okuma noktası açılmasını yasaklayan mimari koruma; (b) `shell` coeffect yayın/temizlik davranışını kilitleyen birim test.

**Kısıtlar:** AGENTS.md §6 checklist'ine uygun (ambient atamaların identity-kontrollü inverseleri korunur; yeni global durum **eklenmez** — azaltılır), kırıcı değişiklik yok (`Rubik.runtime` silinmez, deprekate edilir), ilgisiz refactor yok.

---

## 🔍 Etki Analizi (ön koşul)

Built-in AST sembol grafı ve hedefli grep taramalarıyla çalıştırıldı (GitNexus CLI komutu güvenlik duvarına ikinci kez takıldı — operatör isterse `!allow` ile izin verip `node .gitnexus/run.cjs impact "current_shell" --direction upstream --repo .` ile bağımsız doğrulama yapabilir):

| Sembol | Kullanım noktaları | Risk |
| :--- | :--- | :--- |
| `Rubik.current_shell=` (yaz) | `repl/lifecycle.rb:104` (`warm_up!`), `repl/shell.rb:204` (`stop`, identity-guard'lı nil) | Düşük — ikisi de composition root'ta |
| `Rubik.runtime_manager=` (yaz) | `repl/lifecycle.rb:105`, `repl/shell.rb:205` (identity-guard'lı) | Düşük |
| `Rubik.current_shell` / `.runtime_manager` (ok) | **lib içinde: 0** | — |
| `Rubik.runtime` (ok) | `test/unit/test_dynamic_llm_providers.rb:249` — **tek okuyucu** | Düşük |
| `shell` coeffect (sağla) | `repl/lifecycle.rb:52` — `wire_runtime_context` hash'inde `shell: self` | Zaten mevcut |

**Kritik keşif — işin gerçek kapsamı:**
1. **`shell` zaten coeffect.** `wire_runtime_context` (`lifecycle.rb:46-55`) `shell: self`'i `@runtime_manager.provide(k, v)` ile sağlıyor. Kanonik anahtar `"shell"` (String normalize: `provide` → `name.to_s.downcase`). Öneri 4'ün "çevrilmesi" gereken okuyucu kitlesi boş; eksik olan **ilan** — `Rubik::Coeffects` SSOT'unda (`coeffects.rb:10-19`) `SHELL` sabiti yok, `LEGACY_ALIASES`'ta da geçmiyor. `Coeffects.get(ctx, "shell")` bugün çalışır (`fetch(key, [])` default'u sayesinde) ama anahtar sözleşme dışıdır.
2. **`Context#provide` re-provide güvenli** (`runtime/context.rb:74-87`): aynı anahtar yeniden sağlanırsa değer değişir, **tek** delete-inverse korunur (zero-restart kuralı) → çift yayın döneminde ambient atama + coeffect sağlama çakışmaz.
3. **`stop` zaten temizliyor** (`shell.rb:201` `dispose!` → tüm fiberlar + context; `:204-205` identity-guard'lı ambient nil). Shell coeffect'i dispose ile zaten gidiyor; plan bunu değiştirmez, yalnızca davranışı testle sabitler.
4. **Sorumluluk taraması:** `Loop#shell`, `ShellDeps` `:shell` ve `LoopService#shell` ambient'tan **okumuyor** — constructor injection ile geliyorlar (façade deseni, Plan 87). Bunlar explicit bağımlılık; bu planın kapsamı dışında ve değişmez. `Prompt::ContextBuilder#shell&.config` fallback'i de enjekte edilmiş nesne üzerinden; kapsam dışı.

---

## 🔨 İş Paketleri

### İş Paketi A — `shell` Coeffect'inin SSOT'ta İlanı

#### A1. `lib/rubik/coeffects.rb` — kanonik anahtar ekle

**Neden:** SSOT, "hangi coeffect anahtarları var" sorusunun tek kaynağıdır. `shell` sağlanıp SSOT'ta listelenmiyorsa üçüncü taraf araçlar/sentezlenen kod ambient kökü keşfetmek zorunda kalır — review'in tam endişesi. İlan, ambient kökün meşru alternatifini görünür kılar.

**Değişiklik** (`CONTEXT_INDEX` bloğuna, alfabetik konumda):

```ruby
    SKILL_MANAGER  = "skill_manager"
    SHELL          = "shell"          # REPL composition root (wire_runtime_context); replaces ambient Rubik.current_shell
    ADAPTER_REGISTRY = "adapter_registry"
```

> Not: `LEGACY_ALIASES`'a eklenmez — `shell` için alias yok; `Coeffects.get(ctx, SHELL)` `fetch(key, [])` default'uyla doğru çalışır. Dış bağımlılık yok: `Coeffects`, `repl`'den bağımsız (mimari sınır korunur — guard test B/C bunu doğrular).

#### A2. `lib/rubik/repl/lifecycle.rb` — yayın noktasına sözleşme yorumu

**Değişiklik** (`wire_runtime_context` içinde, `shell: self` satırına):

```ruby
          adapter_registry: @adapter_registry, events: @event_bus, config: @config, shell: self, # SHELL coeffect (Rubik::Coeffects::SHELL) — the sanctioned access path; ambient Rubik.current_shell is deprecated (sunset: Plan 90)
```

**Neden:** Çift yayın dönemi (ambient + coeffect) boyunca gelecek okuyucuyu doğru kapıya yönlendirir. Davranış değişmez: aynı instance, `Context#provide` idempotent.

---

### İş Paketi B — Ambient Okuma Yüzeyinin Geri Sayımı

#### B1. `lib/rubik.rb` — `Rubik.runtime` deprekasyon köprüsü

**Değişiklik** (`runtime` metodu, davranış korunur; uyarı okuma başına **bir kez**):

```ruby
  class << self
    attr_accessor :current_shell, :runtime_manager

    # Deprecated read bridge (review Öneri 4 sunset): resolves the runtime
    # manager from the ambient root. New code must go through the context:
    # Rubik::Coeffects::SHELL coeffect via ctx.require / Manager#context.
    def runtime
      warn_ambient_read_once
      runtime_manager || current_shell&.runtime_manager
    end

    private

    def warn_ambient_read_once
      return if defined?(@ambient_warned) && @ambient_warned

      @ambient_warned = true
      warn "[DEPRECATION] Rubik.runtime is deprecated (sunset). Inject the " \
           "'shell' coeffect (Rubik::Coeffects::SHELL) or read the manager " \
           "from the owning Shell instead."
    end
  end
```

**Kritik detaylar:**
- Uyarı **bir kez** verilir (`@ambient_warned` flag) — sıcak yolda (her tool çağrısı) log gürültüsü olmaz.
- `attr_accessor` satırı değişmez: yazma yüzeyi lifecycle/stop tarafından meşru olarak kullanılmaya devam eder.
- `Rubik.runtime_manager` ve `Rubik.current_shell` **okuma** accessorları korunur (arka uyumluluk); yalnızca türetilmiş `Rubik.runtime` uyarı verir. Tam kaldırma ayrı bir breaking-release işidir — bu planda **değil**.

#### B2. `test/unit/test_dynamic_llm_providers.rb` — davranış + deprekasyon kilidi

**Değişiklik** (satır 248-249 civarı): mevcut `assert_equal shell.runtime_manager, Rubik.runtime` korunur; yanına uyarı doğrulaması eklenir (`assert_output`/`capture_io` ile `[DEPRECATION]` içeriği) ve ikinci okumada uyarının **tekrarlanmadığı** doğrulanır (bir-kez semantiği).

---

### İş Paketi C — Koruma Testleri

#### C1. `test/unit/test_architectural_boundaries.rb` — ambient okuma yasağı

**Neden:** Review'in asıl korkusu "yarın çoğalabilir". Require-boundary guard'ın kardeşi: method-level coupling'i gören araç yok, bu grep-koruması CI'ı bağlar.

**Değişiklik — yeni test metodu** (`test_no_requires_from_core_dirs_back_into_repl` yanına, aynı dosya mantığı: `Dir.glob` + satır taraması):

```ruby
  # Architectural invariant (review Öneri 4): the ambient global root
  # (Rubig.current_shell / runtime_manager / Rubik.runtime) is in sunset.
  # No code may READ it; publishers are the two composition-root files.
  ALLOWED_AMBIENT_FILES = {
    "rubik.rb" => "definition (attr_accessor + deprecated Rubik.runtime bridge)",
    File.join("repl", "lifecycle.rb") => "publisher (warm_up!)",
    File.join("repl", "shell.rb") => "identity-guarded teardown (stop)"
  }.freeze

  def test_no_ambient_global_reads_outside_composition_root
    patterns = [/Rubik\.current_shell/, /Rubik\.runtime_manager/, /Rubik\.runtime\b/]
    violations = []

    Dir.glob(File.join(LIB, "**", "*.rb")).each do |file|
      rel = file.sub("#{LIB}#{File::SEPARATOR}", "")
      next if allowed_ambient_file?(rel)

      File.readlines(file).each_with_index do |line, idx|
        patterns.each do |p|
          violations << "#{file}:#{idx + 1}: #{line.strip}" if line.match?(p)
        end
      end
    end

    assert_empty violations, "Ambient globals must not be read outside the composition root:\n#{violations.join("\n")}"
  end
```

> Not: `lib/rubik.rb` içindeki `def runtime` gövdesi `Rubik.` prefix'i taşımadığı için guard'a takılmaz; tanım dosyası yine de allowlist'te kalır (attr_accessor satırı). Regex'in `Rubik\.runtime\b` — `Rubik.runtime_manager`'ı da yakalar (`\b` runtime'dan sonra durur, `runtime_manager` ayrı pattern ile zaten yakalanır).

#### C2. `test/unit/test_shell_coeffect.rb` — yayın/temizlik davranış kilidi (yeni dosya)

**Neden:** SSOT ilanı + çift yayın dönemi, davranış bozulmadan geçmeli. Dört iddia:

1. **Yayın:** tam-shell kurulumdan sonra `manager.context.get(Rubik::Coeffects::SHELL)` → shell instance'ı (kimlik eşitliği) ve `Rubik.current_shell == shell`.
2. **SSOT okuma yolu:** `Rubik::Coeffects.get(manager.context, Rubik::Coeffects::SHELL)` → aynı instance (alias köprüsü SHELL için gereksiz — doğrudan kanonik okuma).
3. **Temizlik:** `shell.stop` sonrası `Rubik.current_shell.nil?` (identity-guard kendi shell'ini nil'ler) ve `manager.context.disposed?`.
4. **Taze provide:** ayrı bir `Rubik::Runtime::Manager` üzerinde `provide(:shell, x)` → `Coeffects.get(ctx, :shell) == x` (String/Symbol normalize uyumu; re-provide Ω'yı şişirmez — `disposable_count` sabit kalır, zero-restart).

**Kurulum deseni:** mevcut tam-shell testleri izlenir (`Rubik::REPL::Shell.new(config:, output:)` — bkz. `test_agent_step_budget.rb:122`); `warm_up!`'ın `Shell.new` içinde mi yoksa açık `start`'ta mı koştuğu uygulama sırasında bu desenlerden doğrulanır. Dış servis (LLM ağı vs.) gerektirmeyen config kullanılır.

---

## ✅ Doğrulama Planı

```bash
ruby -Itest test/unit/test_shell_coeffect.rb          # yeni davranış kilidi
ruby -Itest test/unit/test_architectural_boundaries.rb # require + ambient korumaları
ruby -Itest test/unit/test_dynamic_llm_providers.rb    # deprekasyon köprüsü
ruby -Itest test/unit/test_runtime_context.rb          # Context provide/unprovide sağlamlığı
bundle exec rake test                                  # tam paket (Öneri 1 sonrası stratifiye edilecek)
```

**Kabul kriterleri:**
- Yeni/koruma testleri yeşil; mevcut suite regresyonsuz.
- `Rubik::Coeffects::SHELL` SSOT'ta tanımlı ve `Coeffects.get` ile okunabiliyor.
- `Rubik.runtime` okuması deprecation uyarısı veriyor (bir kez) ve davranışı koruyor.
- `lib/` içinde ambient okuma sayısı koruma testinde sabitlenmiş: yayıncı/temizleyici 3 dosya dışında 0.

---

## 📝 Açık Sorular (uygulama sırasında kapatılır)

1. `warm_up!` test kurulumlarında nerede koşuyor (`Shell.new` mi, `start` mı)? → C2 kurulum deseni buna göre seçilir.
2. Deprecation uyarısı `ENV["RUBIK_TEST"]==1` altında bastırılmalı mı? Öneri: bastırma — test kendisi uyarıyı yakalıyor; üretim gürültüsü bir-kez flag'le zaten sınırlı.
3. `Rubik.runtime`'ın tamamen kaldırılması: breaking-release notu olarak `README`/`ARCHITECTURE.md` "sunset notu"na işlenir (bu plan kapsamı dışı).
4. ARCHITECTURE.md'de coeffect anahtar tablosunun yeri: uygulama sırasında bakılır; yoksa Bölüm 7 (PR kontrol listesi) yanına kısa "ambient sunset" paragrafı eklenir.

---

## Kapsam Dışı (açıkça)

- `Loop#shell` / `ShellDeps` `:shell` / `LoopService#shell`: constructor-injection ile explicit — dokunulmaz (Plan 87 façade disiplini).
- `Prompt::ContextBuilder#shell&.config` fallback'inin coeffect'e çevrilmesi: ayrı küçük PR.
- `Rubik.current_shell` yazma yüzeyinin kaldırılması: çift yayın dönemi boyunca gerekli (plugins/overlay üçüncü taraf erişimi).

---

## Uygulama Günlüğü

| Tarih | Commit | Not |
| :--- | :--- | :--- |
| 2026-09-14 | — | Plan oluşturuldu (uygulama bekliyor) |
