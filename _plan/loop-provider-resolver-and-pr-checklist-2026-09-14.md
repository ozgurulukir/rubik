# 📋 Plan: Loop ProviderResolver Çıkarımı ve PR İnceleme Kontrol Listesi

> **Kaynak:** [`_reviews/2026-09-14-architectural-review.md`](../_reviews/2026-09-14-architectural-review.md) — **Öneri 3** (Shell/Loop inceltme planı)
> **Tarih:** 14 Eylül 2026 (Pzt)
> **Durum:** ✅ Uygulandı — commit `445f68f` (`refactor(orchestrator): extract ProviderResolver from Loop; add PR review checklist`)
> **Öncül planlar:** [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md) (Loop dekompozisyonu), [75](75-reaktif-yapilandirma-gozlemcisi-sistem-geneli-knob-kablolamasi-ve-canli-rekonfigurasyon.md) (config reaktivitesi), [86](86-deferred-borc-temizligi-artimli-stream-repair-loop-ve-modulerlik.md) / [87](87-shelldeps-facade-ve-artimli-chunk-montaji.md) (ShellDeps façade deseni)

---

## 🎯 Hedef

Review Öneri 3'ün iki bileşenini, tek başına amaçlı ve düşük riskli iş paketlerine böl:

1. **İş Paketi A — `ProviderResolver` çıkarımı:** `Orchestrator::Loop` içindeki provider-config bölümünü (`provider_registry_key`, `provider_llm_config` — loop.rb satır 156–191) ayrı bir `Rubik::Orchestrator::ProviderResolver` sınıfına taşı. Loop ~403 satırdan ~370'e iner; provider-config bilgisinin tek sahibi olur.
2. **İş Paketi B — İnceleme kontrol listesi:** "Shell'e yeni davranış mixin'e mi gitti, çekirdeğe mi?" ve "Loop bunu kullanıyor mu?" sorularını `ARCHITECTURE.md`'e kalıcı bir PR kontrol listesi olarak yaz. (Review'in "style-guide'a yazılmalı" isteği — projede style-guide karşılığı `ARCHITECTURE.md`.)

**Kısıtlar:** AGENTS.md §6 checklist'ine uygun (bağımlılıklar açık, disposal etkisi yok — saf okuma mantığı taşınıyor), yeni bağımlılık yok, kırıcı değişiklik yok, ilgisiz refactor yok.

---

## 🔍 Etki Analizi (ön koşul)

Built-in AST sembol grafı üzerinden çalıştırıldı (GitNexus CLI, güvenlik duvarı nedeniyle engellendi — operatör isterse `!allow` ile izin verip `node .gitnexus/run.cjs impact ... --direction upstream` ile tekrar edebilir):

| Sembol | Arayanlar | Risk |
| :--- | :--- | :--- |
| `Loop#provider_registry_key` (private) | `Loop#provider_llm_config`, `Loop#execute_steps` (loop.rb:176, 206) | Düşük — iki çağrıcı da aynı dosyada |
| `Loop#provider_llm_config` (private) | `Loop#send_llm_request_with_recovery` (loop.rb:231, 242, 243) | Düşük — tek çağrıcı |

**Kritik kısıt — test uyumluluğu:** `test/unit/test_llm_custom_headers_and_config_knobs.rb` içindeki `build_knob_loop` yardımcısı `Rubik::Orchestrator::Loop.allocate` + `instance_variable_set` ile loop kuruyor (`initialize` **çalışmadan**). Bu yüzden resolver `initialize`'de **değil**, ilk kullanımda tembel (lazy) inşa edilmelidir; aksi hâlde `@provider_resolver` nil kalır. Buna ek olarak `test_llm_custom_headers_and_config_knobs.rb` ve `test_dynamic_llm_providers.rb` private metotları `send(:send_llm_request_with_recovery, {})` üzerinden dolaylı çağırır — `send` ile `instance_variable_get`/`define_singleton_method` kullanan başka testler (ör. `test_loop_decomposition.rb`, `test_llm_retry_wiring.rb`) metot adları/sabitler korunursa etkilenmez.

**Sorumluluk sızıntısı taraması:** `delete_suffix("Provider")` kalıbı kod tabanında yalnızca loop.rb:166'da; `ProviderResolver` adı benzersiz; `Repair::Loop`'ta benzer provider-override mantığı yok — çıkarım çakışmasız. `safe_config` bu planın kapsamı **değil** (genel config erişimcisi; `process_step_response` da kullanıyor).

---

## 🔨 İş Paketleri

### İş Paketi A — `ProviderResolver` Çıkarımı

#### A1. `lib/rubik/orchestrator/provider_resolver.rb` — yeni dosya

**Neden:** Provider registry anahtarı ve `llm.*` override çözümlemesi, loop'un adım döngüsüyle ilgisiz saf bir config-okuma sorumluluğu. Ayrı sınıf; (1) Loop'u inceltir, (2) birim testini loop dublosu olmadan yazar, (3) ileride ikinci bir tüketici çıkarsa (ör. `!provider` komutları) tek kaynağa bağlar.

**Değişiklik — yeni dosya, gövde loop'tan *birebir* taşınıyor (yorumlar dahil):**

```ruby
# frozen_string_literal: true

module Rubik
  module Orchestrator
    # Provider-scoped configuration resolution for the orchestrator loop
    # (review Öneri 3; extracted from Loop's provider-config section).
    #
    # Owns two lookups:
    # - registry_key: registry-style key of the active provider — the
    #   explicit provider name (downcased, the way the registry stores
    #   them) when it carries one, else the class name derived the way
    #   builtin providers are registered (Rubik::LLM::OllamaProvider ->
    #   "ollama"). An empty name counts as unnamed, so instances built
    #   outside the registry keep falling back.
    # - llm_config: per-provider llm.* override — providers.<key>.<field>
    #   beats the global llm.<field>, so a provider-specific quirk (e.g. a
    #   broken SSE stack) can be tuned without flipping the knob for every
    #   provider. A scoped nil counts as unset — also the only way to
    #   clear an override back to the global value.
    #
    # The config object is held by reference and values are re-read on
    # every fetch, so !config set / !provider set still apply from the
    # very next turn (config reactivity, Plan 75).
    class ProviderResolver
      def initialize(provider:, config:)
        @provider = provider
        @config = config
      end

      def registry_key
        explicit = @provider.respond_to?(:name) ? @provider.name.to_s.downcase : ""
        return explicit unless explicit.empty?

        @provider.class.name&.split("::")&.last&.delete_suffix("Provider")&.downcase
      end

      def llm_config(key, default)
        prov_key = registry_key
        if prov_key.is_a?(String) && !prov_key.empty? && @config.respond_to?(:fetch)
          val = @config.fetch("providers.#{prov_key}.#{key}", nil)
          return val unless val.nil?
        end

        # Two-arg fetch, not safe_config: safe_config's `fetch(...) || default`
        # would coerce an explicit false (llm.stream=false) into the truthy
        # default, and a one-arg fetch on a plain-Hash config (tests) raises
        # KeyError instead of falling through.
        return default unless @config.respond_to?(:fetch)

        @config.fetch("llm.#{key}", default)
      rescue StandardError
        default
      end
    end
  end
end
```

**Kritik detaylar:**
- Gövdeler loop'taki hâliyle **birebir** taşınır (`@provider`/`@config` resolver ivarlerine çevrilir). Yorumlar yük taşıyıcıdır: boş adın "isimsiz" sayılması, iki-arg `fetch`in gerekçesi, scoped-nil = unset semantiği. Yorum kaybı = gelecekte sessiz semantik regresyonu.
- Yapıcı `(provider:, config:)` anahtar sözcüklü — Loop'tan **geri referans yok**; bağımlılık yönü tek yönlü (Loop → Resolver).
- Dönüşte `nil` config kabul edilir (`@config.respond_to?(:fetch)` guard'ı) — loop'taki mevcut nil-config toleransı korunur.

**Doğrula:** `ruby -Itest test/unit/test_provider_resolver.rb` (A3'te oluşturulacak).

---

#### A2. `lib/rubik/orchestrator/loop.rb` — delegasyon şimleri

**Neden:** Çağrı noktaları (`execute_steps`, `send_llm_request_with_recovery`) ve `send(...)` tabanlı testler değişmeden kalır; public/private yüzey ve imzalar sabitlenir → risk ~sıfır.

**Değişiklik 1 — require ekle** (satır 6 sonrası, `shell_deps` yanına):

```ruby
require_relative "provider_resolver"
```

**Değişiklik 2 — satır 156–191 arasındaki `provider_registry_key` + `provider_llm_config` gövdelerini (yorumlarıyla birlikte) şununla değiştir:**

```ruby
      # Registry-key + llm.* override resolution lives in ProviderResolver
      # (review Öneri 3). Loop keeps thin private delegates with the
      # original names/signatures so call sites and send()-based tests are
      # untouched.
      def provider_registry_key
        provider_resolver.registry_key
      end

      def provider_llm_config(key, default)
        provider_resolver.llm_config(key, default)
      end

      # Built lazily on first use, NOT in initialize: several test doubles
      # construct loops via Class#allocate + instance_variable_set
      # (build_knob_loop), which skips initialize. Reading @provider/
      # @config at first use keeps that pattern working. Memoization is
      # safe: the provider reference is immutable for the loop's lifetime
      # and the config object is held by reference (values re-read per
      # fetch — config reactivity preserved).
      def provider_resolver
        @provider_resolver ||= ProviderResolver.new(provider: @provider, config: @config)
      end
```

**Değişiklik 3 — `initialize` yorum bloğuna (satır 48-50 civarı, Plan 87 E-1 notunun yanına) tek satır ekleyin:** provider-config işbirlikçisinin `ProviderResolver`'a taşındığını ve aynı desen izlendiğini belirten yorum (mixin/çıkarma izinin belgelenmesi — İş Paketi B'nin kod tarafı karşılığı).

**Korunan davranışlar (dikkat):**
- `execute_steps` (satır 206): `prov_name = provider_registry_key || "custom"` — **olduğu gibi kalır**. `registry_key` bugün hep String döner; `|| "custom"` anonim sınıf savunmasıdır, bu refactor'ta dokunulmaz.
- `send_llm_request_with_recovery` (satır 228-244): `provider_llm_config("stream"|"stream_timeout"|"open_timeout", ...)` çağrıları değişmez.
- Loop ~403 → ~370 satır; sembol sayısı 35 → 36 (çıkartılan 2 yerine tembel erişimci 1 eklenir; net hedef: *çözümleme mantığı* loop'tan çıkar, yüzey sabit kalır).

**Doğrula:** `ruby -Itest test/unit/test_llm_custom_headers_and_config_knobs.rb` (knob testleri birebir çalışmalı) + `test_loop_decomposition.rb`.

---

#### A3. `test/unit/test_provider_resolver.rb` — yeni birim test dosyası

**Neden:** Çıkarılan sınıf loop dublosu olmadan test edilebilir olmalı (çıkarımın temel getirisi). `test_helper` yükleme deseni: `require_relative "../test_helper"`.

**Kapsanacak davranışlar (eski loop testlerinin elle tutmayan boşlukları):**

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

module Rubik
  module Orchestrator
    class DummyShapeProvider; end # class-name fallback -> "dummyshape"

    module LLM
      class FakeOllamaProvider; end # namespace fallback -> "fakeollama"
    end

    class TestProviderResolver < Minitest::Test
      def test_registry_key_prefers_explicit_name_downcased
        provider = Object.new
        def provider.name = "InternLM"
        assert_equal "internlm", build(provider).registry_key
      end

      def test_registry_key_strips_provider_suffix_from_class_name
        assert_equal "dummyshape", build(DummyShapeProvider.new).registry_key
      end

      def test_registry_key_uses_last_namespace_segment
        assert_equal "fakeollama", build(LLM::FakeOllamaProvider.new).registry_key
      end

      def test_registry_key_empty_name_counts_as_unnamed
        provider = Object.new
        def provider.name = ""
        assert_equal "dummyshape", build(provider, klass: DummyShapeProvider).registry_key
      end

      def test_registry_key_provider_without_name_method
        assert_equal "dummyshape", build(Object.new, klass: DummyShapeProvider).registry_key
      end

      def test_provider_scoped_override_beats_global
        cfg = config_with("providers.internlm.stream_timeout" => 90, "llm.stream_timeout" => 150)
        assert_equal 90, build(named("internlm"), cfg).llm_config("stream_timeout", 120)
      end

      def test_scoped_nil_counts_as_unset_falls_through_to_global
        cfg = config_with("providers.internlm.stream_timeout" => nil, "llm.stream_timeout" => 150)
        assert_equal 150, build(named("internlm"), cfg).llm_config("stream_timeout", 120)
      end

      def test_explicit_false_is_preserved_not_coerced_to_default
        cfg = config_with("llm.stream" => false)
        assert_equal false, build(named("internlm"), cfg).llm_config("stream", true)
      end

      def test_plain_hash_config_missing_key_returns_default_not_keyerror
        assert_equal true, build(named("internlm"), {}).llm_config("stream", true)
      end

      def test_config_without_fetch_returns_default
        assert_equal 42, build(named("internlm"), nil).llm_config("stream_timeout", 42)
      end

      def test_config_fetch_crash_returns_default
        boom = Object.new
        def boom.fetch(*) = raise "boom"
        assert_equal 42, build(named("internlm"), boom).llm_config("stream_timeout", 42)
      end

      private

      def build(provider, config = nil, klass: nil)
        # klass, anonim provider'ın class-name fallback'ini test içi dublo
        # sınıfına bağlamak için singleton_class ile taklit edilir.
        if klass
          provider.define_singleton_method(:class) { klass }
        end
        ProviderResolver.new(provider: provider, config: config)
      end

      def named(name)
        provider = Object.new
        provider.define_singleton_method(:name) { name }
        provider
      end

      def config_with(pairs)
        Rubik::Config.new(root_dir: Dir.mktmpdir, home_dir: Dir.mktmpdir).tap do |cfg|
          pairs.each { |k, v| cfg.set(k, v) }
        end
      end
    end
  end
end
```

*(Taslak — uygulama aşamasında `build`/`named` yardımcıları sadeleştirilebilir; kritik olan yukarıdaki 11 davranışın kaplanması. `Rubik::Config#set` imzası uygulamada doğrulanır; uyumsuzlukta `Hash` tabanlı sahte config'e düşülür.)*

**Ayrıca** `test/unit/test_llm_custom_headers_and_config_knobs.rb` içine **tek test** eklenir — allocate-uyumluluk sözleşmesini kilitler:

```ruby
def test_provider_registry_key_works_on_allocated_loop
  mock_loop = Rubik::Orchestrator::Loop.allocate
  provider = Object.new
  def provider.name = "internlm"
  mock_loop.instance_variable_set(:@provider, provider)
  assert_equal "internlm", mock_loop.send(:provider_registry_key)
end
```

**Doğrula:** `ruby -Itest test/unit/test_provider_resolver.rb` → 11 run, 0 failure; `test_llm_custom_headers_and_config_knobs.rb` mevcut + 1 run ile yeşil.

---

### İş Paketi B — Mimari İnceleme Kontrol Listesi

#### B1. `ARCHITECTURE.md` — yeni bölüm "7. PR İnceleme Kontrol Listesi"

**Neden:** Review Öneri 3, Shell'in kalan 50 sembolü için "yeni davranış mixin'e mi gitti, çekirdeğe mi?" sorusunun kalıcı bir yere yazılmasını istiyor. `AGENTS.md` protokol-belgesi (gitnexus bloğu yönetiminde), `README.md` kullanıcıya dönük — katkıda dönüşük tasarım belgesi `ARCHITECTURE.md`. Require-seviyesi değişmezler zaten CI'da (`test/unit/test_architectural_boundaries.rb`); bu liste, aracın göremediği **metot-seviyesi** coupling'i kapsar.

**Değişiklik — dosya sonuna (Bölüm 6 sonrası) ekle:**

```markdown
## 🔍 7. PR İnceleme Kontrol Listesi (Shell / Loop Büyüme Disiplini)

> Kaynak: `_reviews/2026-09-14-architectural-review.md` Öneri 3. Require-seviyesi
> değişmezler (`orchestrator/runtime/tools/llm → repl` yok) CI'da
> `test/unit/test_architectural_boundaries.rb` ile zorlanır; aşağıdaki liste
> statik analizin göremediği metot-seviyesi coupling içindir.

`lib/rubik/repl/shell.rb` veya `lib/rubik/orchestrator/loop.rb` dokunulan
her PR'da inceleyici şunları sorar:

- [ ] **Yeni davranış mixin'e mi, çekirdeğe mi?** Shell'e yeni bir public
      metot/ömür döngüsü davranışı eklerken önce mixin evi sorulur:
      lifecycle, presentation, config_wiring, composition, hooks,
      confirmations, turn_recorder. Çekirdek sınıfa ek yalnızca sınıflar-arası
      orkestrasyon kodu için.
- [ ] **Loop yeni Shell yüzeyine mi dokunuyor?** Orchestrator'dan Shell'e
      erişim yalnızca `ShellDeps` daraltıcı üzerinden. Yeni bir Shell metodu
      Loop'tan çağrılacaksa önce ShellDeps `SURFACE`'e eklenip eklenmeyeceği
      tartışılır; doğrudan `shell.xxx` reach-through red sebebidir.
- [ ] **Yeni bir işbirlikçi çıkarılmalı mı?** Aynı sorumlulukta ≥2 özel metot
      birikmişse (örn. provider-config → `ProviderResolver`), ShellDeps/StepExecutor
      deseni izlenir: dar yapıcı enjeksiyonu + Loop'ta private delegasyon şimleri.
- [ ] **Satır/sembol bütçesi:** PR, Shell'i ~600 satırın veya Loop'u ~400
      satırın üzerine çıkarıyorsa gerekçe zorunludur; aksi hâlde çıkarma
      (extraction) planlanır.
```

**Doğrula:** Dokümantasyon değişikliği; test gerekmez. Bölüm numarası/kafa yapısı mevcut başlıklarla çakışmamalı (şu an 1–6 var).

---

## ✅ Doğrulama Planı

```text
ruby -Itest test/unit/test_provider_resolver.rb
ruby -Itest test/unit/test_llm_custom_headers_and_config_knobs.rb
ruby -Itest test/unit/test_loop_decomposition.rb
ruby -Itest test/unit/test_orchestrator_loop.rb
ruby -Itest test/unit/test_agent_step_budget.rb
ruby -Itest test/unit/test_shell_deps.rb
```

Son adım tam paket: `bundle exec rake test` (Windows'ta >5 dk; 300 sn timeout'u aşabilir — review Bulgu 4'ün bilinen durumu, stratifikasyon Öneri 1'de ayrı iş).

`git diff` yalnızca şu 5 dosyayı göstermelidir:
- `lib/rubik/orchestrator/provider_resolver.rb` *(yeni)*
- `lib/rubik/orchestrator/loop.rb`
- `test/unit/test_provider_resolver.rb` *(yeni)*
- `test/unit/test_llm_custom_headers_and_config_knobs.rb` *(+1 test)*
- `ARCHITECTURE.md`

---

## 🏛️ Mimari Kararlar

1. **Yapıcı `(provider:, config:)` — Loop referansı değil.** Resolver'a loop vermek, çözülmekte olan coupling'i yeniden yaratır. Dar yapıcı, birim testi loop dublosuz mümkün kılar. Bağımlılık yönü: Loop → Resolver, geri dönüş yok.
2. **Tembel (lazy) memoize erişimci, `initialize`'de kurulum değil.** `build_knob_loop` desenli testler `Loop.allocate` ile kuruyor; `initialize`'de inşa bu testleri kırar. Memoizasyon güvenli: provider referansı loop ömrünce değişmez; config **nesnesi** referansla tutulur, **değerler** her `fetch`'te taze okunur → config reaktivitesi (Plan 75) korunur.
3. **Aynı ad/imzalı private delegasyon şimleri.** Çağrı noktaları ve `send(...)` tabanlı testler değişmez; diff minimaldir. Alternatif (çağrı noktalarını `provider_resolver.llm_config(...)`'e çevirmek) reddedildi: gereksiz churn, review yüzeyi büyür.
4. **Gövde + yorumlar birebir taşınır.** Yorumlar yük taşıyıcıdır (iki-arg fetch gerekçesi, scoped-nil semantiği, boş-ad fallback'i). Yorum kaybı ileride sessiz semantik bozulmasına açar.
5. **Checklist `ARCHITECTURE.md`'e.** Protokol-belgesi `AGENTS.md` gitnexus-blok yönetiminde; `ARCHITECTURE.md` katkıda dönüşük tasarım belgesi ve zaten değişmezleri (Bölüm 4) barındırıyor.
6. **`safe_config` Loop'ta kalır.** Provider'a özgü değil; `process_step_response` da kullanıyor. Kapsam dışı.
7. **`provider_registry_key || "custom"` savunması korunur.** Bugün nil dönmese de anonim sınıf kenarı savunulur; bu refactor semantik değiştirmez.

---

## ❓ Açık Sorular

- **İkinci tüketici senaryosu:** `registry_key` mantığı ileride `LLM::BaseProvider#registry_key` olarak sağlayıcı tarafına taşınabilir mi? İlk geçişte hayır — üç yerleşik + dinamik kayıt yoluna dokunmak, orchestrator'ın sahibi olduğu bir adlandırma kuralı için geniş yüzey değişimidir. İkinci bir tüketici belirdiğinde yeniden değerlendirilir.
- **Öneri 4 ile eş zamanlılık:** `Rubik.current_shell` okuyan noktaların `ctx.require("shell")`'e çevrilmesi aynı PR'da yapılmaz — review'in iş paketleri tek amaçlı tutulur; Öneri 4 ayrı plan olur.
- **Plan tamamlanınca:** Review belgesindeki Öneri 3 satırı, önceki iki kapanışın izlediği desenle ("✅ Yapıldı (commit `…`)") işaretlenir; `_plan/00-index.md` güncellenmez (ad-hoc plan formatı, `synthesis-crud-and-architectural-guard-2026-09-14.md` örneğindeki gibi).

---

## 📝 Uygulama Günlüğü

> **Sonuç:** ✅ Uygulandı ve commit'lendi — `445f68f`. Tüm adımlar (A1–A3, B1) plana uygun; plan sapması yok.

| Adım | Durum | Notlar |
|---|---|---|
| **A1** `provider_resolver.rb` | ✅ | Gövdeler + yorumlar birebir taşındı; `llm_config` içinde `provider_registry_key` → `registry_key` çağrısı resolver-ivariance uyarlandı |
| **A2** loop.rb şimleri | ✅ | Require + delegasyon şimleri + tembel `provider_resolver` erişimcisi; `initialize` yorum izi eklendi; 403 → 394 satır |
| **A3** resolver testleri | ✅ | 11 davranış yeşil; `Rubik::Config` `require "rubik"` ile gelir (ayrı require gerekmedi) |
| **A3+** knob kilidi | ✅ | `test_provider_registry_key_works_on_allocated_loop` — allocate sözleşmesi kilitli |
| **B1** ARCHITECTURE.md Bölüm 7 | ✅ | 4 madde; Bölüm 6 başlık/numaralandırma çatışması yok |

**Doğrulama (çalıştırıldığı gibi):**
```
ruby -Itest test/unit/test_provider_resolver.rb                     # 11 runs, 0 failures
ruby -Itest test/unit/test_llm_custom_headers_and_config_knobs.rb   # 18 runs, 4 errors (önceden var olan)
ruby -Itest test/unit/test_loop_decomposition.rb                    # yeşil
ruby -Itest test/unit/test_orchestrator_loop.rb                     # yeşil
ruby -Itest test/unit/test_shell_deps.rb (+ step_budget, arch boundaries)  # 10 runs, 0 failures
```

**Bilinen ortam sorunu (regresyon değil):** `test_llm_custom_headers_and_config_knobs.rb`'deki 4 `stub` hatası `minitest/mock`'un bu Ruby 4.0.6 ortamında otomatik yüklenmemesinden — HEAD'de de aynı (17 run, 4 error). `git stash` ile doğrulandı.
