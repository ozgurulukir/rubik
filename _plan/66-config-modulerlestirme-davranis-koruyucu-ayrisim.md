# Plan 66 — Config Modülerleştirme: Davranış-Koruyucu Sorumluluk Ayırımı

> **Domain:** Altyapı / Yapılandırma (Config)
> **Kaynak:** Dış değerlendirme (Ağustos 2026) — "Concern 1: Config Class Complexity" + "Key Recommendation 4: Extract Config Sub-Modules"
> **Durum:** ✅ Tamamlandı
> **Öncül Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md) · [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) · [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md) · [62](62-rubocop-sifir-uyari-temizligi-davranis-koruyucu-kademeli-strateji.md) · [63](63-dis-degerlendirme-tavsiye-triyaji-ve-davranis-koruyucu-iyilestirmeler.md)

---

## 1. Amaç

`Config` sınıfı (489 satır) beş ayrı sorumluluğu tek gövdede taşıyor: varsayılan şema, yükleme/merge, kalıcılık (YAML::Store), tipli erişim, doğrulama. Bu plan, **public API'yi birebir koruyarak** sınıfı odaklı mixin modüllerine ayırır — Plan 63 Faz B (Composition çıkarma) ve Plan 62'nin davranış-koruyucu disiplininin aynı yöntemle uygulanması. Yeniden yazım değil, saf taşıma.

## 2. Kanıt ve Triyaj (kod tabanından)

Değerlendirmenin "Config Class Complexity" tespiti **haklı (ölçülü biçimde)** — "Code Complexity ⭐⭐⭐" notunun ana gerekçesi bu dosya:

| Bölüm | Konum | Boyut/Not |
| :--- | :--- | :--- |
| `DEFAULT_CONFIG` sabiti | `config.rb:9-127` | 119 satır (dosyanın ~%25'i) |
| `save!` | `config.rb:297-354` | 58 satır; tek yöntemde YAML::Store işlemi + derin merge + model override + şema doğrulama + abort + chmod |
| Derin yardımcılar | `config.rb:416-456` | `deep_dup` / `deep_merge` / `deep_stringify_keys` — genel amaçlı işlemler |
| Şema doğrulama | `config.rb:458-486` | `validate_schema` + fuzzy öneri üretimi |
| Tipli erişim | `config.rb:256-295` | `model_spec` / `set_model_spec` / `verbosity*` |

Ancak sınıf **yoğun test güvencesi altında** (`test_config.rb`, `test_config_persistence.rb`, `test_config_yaml_store.rb`, `test_ui_statusline_banner_config.rb`) ve her katman onu okuyor — burada doğru araç mixin ayrışımıdır; devrik yeniden yazım (ör. her erişimi yeni bir nesne grafiğine geçirmek) riski gerekçeyle orantısız olur. Değerlendirmenin önerdiği bölünme (schema, store, merge, migration) benimsenir; "migration" kalemi mevcut kodda ayrı bir yöntem olmadığından `save!` içindeki model-override mantığıyla `Store`'a gider.

## 3. Kapsam — Fazlar

### Faz A — Mixin ayrışımı (`lib/rubik/config/`)
Yeni dosya düzeni; `Config` public API'si (`fetch`, `[]`, `set`, `save!`, `transaction`, `model_spec`, `set_model_spec`, `verbosity`, `verbosity_level`, `parse_scalar_value`, `store_for`, yol yardımcıları, `attr_reader`'lar) **birebir korunur**:

- `config/defaults.rb` → `Config::Defaults`: `DEFAULT_CONFIG` + `validate_schema` (genişletilmiş modül; `@warnings` ivar'ını kullanan kısımlarıyla).
- `config/deep_ops.rb` → `Config::DeepOps`: `deep_dup` / `deep_merge` / `deep_stringify_keys` (durumsuz yardımcılar).
- `config/store.rb` → `Config::Store`: `store_for` / `transaction` / `save!` gövdesi + `load_yaml` / `ensure_rubik_directories` / `global_config_path` / `project_config_path` (kalıcılık sorumluluğu).
- `config.rb` → koordinasyon: `initialize`, `load_merged_config`, tipli erişim (`model_spec`, `verbosity*`, `set`, `parse_scalar_value`, `fetch`, `[]`), `include Defaults, DeepOps, Store`. Sabit erişimini korumak için `DEFAULT_CONFIG = Defaults::DEFAULT_CONFIG` veya benzeri yöntemlerle doğrudan erişim garanti edilir.

### Faz B — Muhafaza testi ve belge
- `test/unit/test_module_hygiene.rb` içine satır tavanları: `config.rb < 200`, her mixin `< 150` (Plan 63'teki `composition.rb < 120` muhafazasıyla aynı kalıp).
- Bu plan dokümanına uygulama notu: hangi yöntem nereye taşındı (inceleme için harita).

### Faz C — Doğrulama kapısı
- Tam `rake test`: **tek bir config testi de değişmez** (davranış-koruyucu kriter; mevcut 4 test dosyası + dolaylı tüketiciler).
- Karakter karşılaştırma: `git diff` yalnızca taşıma + `require_relative` satırları göstermeli (iş mantığı diff'i sıfıra yakın).

## 4. Kapsam Dışı (bilinçli)

- **`fetch`/`set`/`parse_scalar_value` davranış değişiklikleri** — tüketiciler (Loop, providers, REPL) mevcut kontrata kilitli.
- **YAML::Store → düz dosya geçişi** — ayrı kalıcılık konusu (Plan 25 emsali, gerekçe yok).
- **`validate_schema` strict modunun varsayılanlaştırılması** — davranış değişimi; bu plan yalnızca taşır.
- Şemanın ayrı bir DSL'e (JSON Schema vb.) çevrilmesi — değerlendirme bunu önermiyor, Plan 62 disiplini de gerek görmediyor.

## 5. Riskler ve Notlar

- **En yüksek riskli adım `save!`** (idempotans + abort + chmod sırası): taşıma sırasında yöntem gövdesi satır satır aynı kalır; yalnızca `@stores`/`@data`/`@warnings` ivar erişimleri mixin bağlamında çalışır (Ruby mixin'ler ivar'ı paylaşır — davranış değişimi yok).
- `Config`'i `include` eden/kalıtlayan üçüncü taraf yok (Gem içi tek sınıf; `Rubik::Config` doğrudan kullanılıyor) — kamu API'si sınıf düzeyinde sabit.
- `DEFAULT_CONFIG`'in `freeze`'i ve sabit kimliği korunur (nesne kimliğine dayanan test varsa — Faz C'de doğrulanır).
- Windows: yeni dosyalar LF ile yazılır (mevcut normalizasyon disiplini).

## 6. Kabul Kriterleri

- [ ] `git diff` yalnızca taşıma gösteriyor (iş mantığı satırı değişmiyor).
- [ ] Tam `rake test` yeşil (özellikle 4 config test dosyası birebir), `rubocop` 0 ihlal.
- [ ] Muhafaza testi (`config.rb < 200`, mixin'ler `< 150`) `test_module_hygiene.rb`'de.
- [ ] README/AGENTS.md'de Config API'si için bir cümle bile değişmiyor (API sabit).

## 7. Uygulama Sonucu

*(Uygulama sonrası doldurulacak: commit tablosu, test sayıları, sapmalar.)*

## 8. Disiplin

Her faz sonrası: tam `rake test` + `rubocop` kapısı, Windows'ta LF normalizasyonu, faz başına anlamlı commit. `save!`/`fetch`/`set` taşınmadan önce GitNexus `impact` (erişim yoksa Plan 63 emsaliyle explorer agent etki analizi; `fetch` kod tabanının en çok çağrılan yöntemlerinden biridir — etki yarıçapı raporlanır).
