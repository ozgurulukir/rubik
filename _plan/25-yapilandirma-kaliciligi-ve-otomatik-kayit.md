# 25 — Yapılandırma Kalıcılığı (Persistent Configuration), Çok Katmanlı Kaydetme ve Otomatik Hatırlama

**Zorluk:** Kolay–Orta · **Öneri kaynağı:** Kullanıcı Geri Bildirimi · **Faz:** 5 (Kullanıcı Deneyimi & Kalıcılık)  
**İlgili Planlar:** [01 — Proje İskeleti ve Konfigürasyon](01-proje-iskeleti-ve-konfigurasyon.md) · [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [17 — Native LLM & Model Yönlendirme](17-native-tool-calling-ve-model-yonlendirme.md) · [Index](index.md)

---

## 🔍 Tespit Edilen Problem

Kullanıcı REPL içerisindeyken `!model set default openai/gpt-4o` veya `!model ollama/qwen2.5-coder` komutlarıyla model/sağlayıcı değiştirdiğinde, bu değişiklik yalnızca oturumun bellek içi (`in-memory`) `@config.data` nesnesine yazılmakta; diske (`~/.rubik/config.yml` veya `.rubik/config.yml`) kalıcı olarak **kaydedilmemektedir**.

Bu nedenle Rubik kapatılıp başka bir repo veya oturumda yeniden çalıştırıldığında yapılan ayarlar sıfırlanmakta ve varsayılan model geri gelmektedir.

---

## 🎯 Çözüm ve Amaç

1. **Konfigürasyon Diske Kaydetme (`Rubik::Config#save!`):**
   - `:global` kapsamı: `~/.rubik/config.yml` dosyasına yazar (tüm projelerde evrensel geçerli olur).
   - `:project` kapsamı: Projedeki `.rubik/config.yml` (veya `rubik.yml`) dosyasına yazar.
2. **Otomatik Kalıcılık (Auto-Persistence):**
   - `!model` ve `!model set` komutları çalıştırıldığında ayar anında `~/.rubik/config.yml`'e kaydedilir (istenirse `--project` bayrağıyla o repoya özgü kılınabilir).
   - `!config set <key> <val> [--global|--project]` komutunun ayarları diske yazması sağlanır.
3. **Çok Katmanlı Yükleme Sıralaması:**
   - 1. Yerleşik varsayılanlar (`DEFAULT_CONFIG`)
   - 2. Global kullanıcı ayarları (`~/.rubik/config.yml`)
   - 3. Proje ayarları (`.rubik/config.yml` veya `rubik.yml`)
   - 4. Ortam Değişkenleri (`RUBIK_MODEL`, `OLLAMA_HOST` vb.)

---

## 📋 Görevler

1. `Rubik::Config` Sınıfı Genişletmesi (`lib/rubik/config.rb`):
   - `set(key, value, persist: :global)` metodu ekleme.
   - `set_model_spec(role, provider:, name:, host: nil, persist: :global)` metoduna otomatik kaydetme desteği ekleme.
   - `save!(scope: :global)` ve `save_file(path, data)` metotları ile temiz YAML yazma.
   - Proje içi `.rubik/config.yml` desteğini `load_merged_config`'e dahil etme.
2. REPL Komut Güncellemeleri (`lib/rubik/repl/shell.rb`):
   - `!model` komutunun `set_model_spec(..., persist: scope)` çağırarak kullanıcıya `"Saved to ~/.rubik/config.yml"` onayı vermesi.
   - `!model set <role> <model> [--project|--global]` desteği.
   - `!config set <key> <val> [--project|--global]` desteği.
   - `!config path` komutu ile aktif dosya konumlarını listeleme.
3. Birim Testleri:
   - `test/unit/test_config_persistence.rb` oluşturma ve doğrulanması.

---

## 🧪 Kabul Kriterleri

- [ ] `!model ollama/qwen2.5-coder` komutu çalıştırıldığında ayar `~/.rubik/config.yml` dosyasına yazılır.
- [ ] Rubik yeniden başlatıldığında veya başka bir dizinde açıldığında seçilen model hatırlanır.
- [ ] `!model set fast anthropic/claude-3-5-haiku --project` denildiğinde ayar sadece o projenin `.rubik/config.yml` dosyasına kaydedilir.
- [ ] `!config path` komutu global ve proje konfigürasyon dosyası yollarını gösterir.
