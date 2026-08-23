# 📋 Plan 38: YAML::Store ile Güvenli, Eşzamanlı ve Transaksiyonel Yapılandırma Kalıcılığı Refaktörü

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 5 (Kalıcılık, Güvenilirlik & Eşzamanlılık)  
> **İlgili Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [37](37-kademeli-verbosity-ayarlari-ve-canli-ajan-izleme.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum (`File.write` ve `YAML.safe_load`)
Şu anda `Rubik::Config` (`lib/rubik/config.rb`):
1. **İlkel Dosya I/O:** `File.read` + `YAML.safe_load` ve `File.write(target_path, YAML.dump(...))` yöntemini kullanmaktadır.
2. **Yarış Durumları (Race Conditions) & Kilit Eksikliği:** Birden fazla eşzamanlı işlem (örneğin arka plan araçları, subagent'lar, paralel testler veya çoklu REPL oturumları) aynı anda `~/.rubik/config.yml` ya da `.rubik/config.yml` dosyasına yazmaya çalıştığında dosya kilit mekanizması (`flock`) olmadığı için YAML dosyası bozulabilir (`corrupted/partial write`).
3. **Atomik Transaksiyon ve Rollback Yoksunluğu:** Birden fazla ayar (örn. `!provider add` ile hem endpoint, hem key, hem modeller listesi) güncellenirken işlem ortasında bir hata veya doğrulama hatası oluşursa, kısmi yazılmış tutarsız durum dosyada kalabilmektedir. Bu durum [`AGENTS.md`](../AGENTS.md) Temel İlkesi olan **Atomic Failure Rollback** ile çelişmektedir.

### Çözüm: Ruby 3.3 `YAML::Store` (Standart Kütüphane)
Ruby 3.3'te yerleşik olarak bulunan [`YAML::Store`](https://docs.ruby-lang.org/en/3.3/YAML/Store.html) (`yaml/store`):
- `PStore` üzerine inşa edilmiştir ve dosya düzeyinde atomik **`flock` kilitleme** (file locking) sağlar.
- **ACID Transaksiyonlar:** `store.transaction { ... }` bloğu içinde yapılan tüm değişiklikler tek bir atomik adımda diske yazılır.
- **Salt Okunur Kilit Desteği:** `store.transaction(true) { ... }` ile paylaşımlı okuma kilidi alınarak eşzamanlı güvenli okuma sağlanır.
- **Hata Anında Geri Alma (`store.abort`):** Doğrulama hatası veya istisna durumunda `abort` çağrılarak dosya önceki sağlam durumuna anında döndürülür.
- **İnsan Tarafından Okunabilir/Düzenlenebilir YAML:** Standart YAML formatında saklar; kullanıcının dosyayı favori metin düzenleyicisinde elle değiştirmesini engellemez.

---

## 🏛️ 2. Mimari Bileşenler ve Tasarım

```
                              ┌───────────────────────────────────┐
                              │           Rubik::Config           │
                              └─────────────────┬─────────────────┘
                                                │
                       ┌────────────────────────┴────────────────────────┐
                       ▼                                                 ▼
        ┌─────────────────────────────┐                   ┌─────────────────────────────┐
        │  Global YAML::Store         │                   │  Project YAML::Store        │
        │  (~/.rubik/config.yml)      │                   │  (.rubik/config.yml)        │
        ├─────────────────────────────┤                   ├─────────────────────────────┤
        │ • flock process safety      │                   │ • flock process safety      │
        │ • store.transaction(true)   │                   │ • store.transaction(true)   │
        │ • atomic commit / abort     │                   │ • atomic commit / abort     │
        └─────────────────────────────┘                   └─────────────────────────────┘
```

### A. `Rubik::Config` Yeniden Yapılandırması (`lib/rubik/config.rb`)

1. **`store_for(scope)` Yardımcı Metodu:**
   ```ruby
   require "yaml/store"

   def store_for(scope = :project)
     path = (scope.to_sym == :global) ? global_config_path : project_config_path
     FileUtils.mkdir_p(File.dirname(path))
     YAML::Store.new(path, true) # true = thread_safe
   end
   ```

2. **Transaksiyonel Okuma (`load_merged_config`):**
   - Global ve proje store'larından `transaction(true)` ile güvenli okuma.
   - `DEFAULT_CONFIG` ile transaksiyon içinde derin birleştirme (`deep_merge`).

3. **Transaksiyonel Kaydetme (`save!` ve `transaction` API):**
   ```ruby
   def transaction(scope = :project, read_only: false, &block)
     store = store_for(scope)
     store.transaction(read_only) do
       yield store
     end
   end
   ```

4. **Atomik `save!` Implementasyonu:**
   ```ruby
   def save!(scope = :global)
     scope_sym = scope.to_s.downcase.to_sym
     target_path = (scope_sym == :project) ? project_config_path : global_config_path
     store = store_for(scope_sym)

     store.transaction do
       # Mevcut disk verisini oku
       roots = store.roots
       existing = roots.each_with_object({}) { |k, h| h[k] = store[k] }
       
       # Delta'yı birleştir
       merged = deep_merge(existing, @data)
       
       # Şema doğrulaması - Hata varsa abort ile atomik geri al
       errors = validate_schema_strict(merged)
       if errors.any?
         store.abort
         return { ok: false, error: errors.join(", ") }
       end

       # Verileri store'a yaz
       merged.each do |k, v|
         store[k] = v
       end
     end
     { ok: true, path: target_path, scope: scope_sym }
   rescue StandardError => e
     { ok: false, error: e.message }
   end
   ```

5. **`set` ve `set_model_spec` Metotlarının Güçlendirilmesi:**
   - Çoklu anahtar güncellemelerinin tek bir atomik `transaction` bloğu içinde işletilmesi.

---

### B. REPL Kabuğu Entegrasyonu (`lib/rubik/repl/shell.rb`)

`!provider`, `!model`, `!autoapply`, `!steps`, `!verbosity` ve `!config` komutları artık arka planda `YAML::Store` transaksiyon güvencesiyle çalışır. Disk I/O sırasında oluşabilecek kesintilerde (`SIGINT`, elektrik kesintisi, süreç sonlandırma) konfigürasyon dosyası asla yarım/bozuk formatta kalmaz.

---

## 🧪 3. Test ve Doğrulama Planı

`test/unit/test_config_yaml_store.rb`:
1. **Transaksiyonel Okuma & Yazma Testi:** `YAML::Store` üzerinden ayarların atomik yazılması ve okunması.
2. **`abort` ile Rollback Testi:** Geçersiz şema veya işlem iptalinde dosyanın önceki sağlam içeriğini koruması.
3. **Eşzamanlılık & Thread-Safety Testi:** Birden fazla thread'in aynı anda `Config#set` ve `save!` çağırması durumunda dosya bütünlüğünün bozulmaması.
4. **Mevcut YAML Dosyalarıyla Geriye Dönük Uyumluluk:** Elle yazılmış `.rubik/config.yml` dosyalarının sorunsuz okunup güncellenebilmesi.
5. **Genel Test Regresyonu:** Projedeki tüm 201 birim ve entegrasyon testinin %100 yeşil kalması.

---

## 🚀 4. Uygulama Adımları

1. **Adım 1:** `lib/rubik/config.rb` dosyasına `require "yaml/store"` ekle; `store_for`, `transaction` ve `save!` metodlarını `YAML::Store` ile refaktör et.
2. **Adım 2:** Şema doğrulama ve hata durumlarında `store.abort` mekanizmasını entegre et.
3. **Adım 3:** `test/unit/test_config_yaml_store.rb` test paketini oluştur; eşzamanlılık ve atomik rollback testlerini yaz.
4. **Adım 4:** `test/unit/test_config.rb` ve `test/unit/test_config_persistence.rb` regresyon testlerini doğrula.
5. **Adım 5:** `_plan/00-index.md`, `_plan/index.md` ve `CONFIG.md` belgelerini Plan 38 ile senkronize et.
