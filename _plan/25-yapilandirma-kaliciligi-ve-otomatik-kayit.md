# 25 — Yapılandırma Kalıcılığı (Persistent Configuration), Çok Katmanlı Kaydetme ve Otomatik Hatırlama

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Kolay–Orta · **Öneri kaynağı:** Kullanıcı Geri Bildirimi · **Faz:** 5 (Kullanıcı Deneyimi & Kalıcılık)  
**İlgili Planlar:** [01 — Proje İskeleti ve Konfigürasyon](01-proje-iskeleti-ve-konfigurasyon.md) · [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [17 — Native LLM & Model Yönlendirme](17-native-tool-calling-ve-model-yonlendirme.md) · [Index](index.md)

---

## 🔍 Tespit Edilen Problem

Kullanıcı REPL içerisindeyken `!model set default openai/gpt-4o` veya `!model ollama/qwen2.5-coder` komutlarıyla model/sağlayıcı değiştirdiğinde, bu değişiklik yalnızca oturumun bellek içi (`in-memory`) `@config.data` nesnesine yazılmakta; diske (`~/.rubik/config.yml` veya `.rubik/config.yml`) kalıcı olarak **kaydedilmemekteydi**.

Bu nedenle Rubik kapatılıp başka bir repo veya oturumda yeniden çalıştırıldığında yapılan ayarlar sıfırlanmaktaydı.

---

## 🎯 Çözüm ve Amaç

1. **Konfigürasyon Diske Kaydetme (`Rubik::Config#save!`):**
   - `:global` kapsamı: `~/.rubik/config.yml` dosyasına yazar (tüm projelerde evrensel geçerli olur).
   - `:project` kapsamı: Projedeki `.rubik/config.yml` (veya `rubik.yml`) dosyasına yazar.
2. **Otomatik Kalıcılık (Auto-Persistence):**
   - `!model` ve `!model set` komutları çalıştırıldığında ayar anında `~/.rubik/config.yml`'e kaydedilir (istenirse `--project` veya `-p` bayrağıyla o repoya özgü kılınabilir).
   - `!config set <key> <val> [--project|--global]` komutunun ayarları diske yazması sağlanır.
3. **Çok Katmanlı Yükleme Sıralaması:**
   - 1. Yerleşik varsayılanlar (`DEFAULT_CONFIG`)
   - 2. Global kullanıcı ayarları (`~/.rubik/config.yml`)
   - 3. Proje ayarları (`.rubik/config.yml` veya `rubik.yml`)
   - 4. Ortam Değişkenleri (`RUBIK_MODEL`, `OLLAMA_HOST` vb.)

---

## 📋 Tamamlanan Görevler

1. `Rubik::Config` Sınıfı Genişletmesi (`lib/rubik/config.rb`):
   - `global_config_path` ve `project_config_path` metodları eklendi.
   - `set(key, value, persist: :global)` ve `set_model_spec(..., persist: :global)` ile otomatik dosya kaydetme desteği eklendi.
   - `save!(scope = :global)` metodu ile güvenli YAML yazımı ve var olan dosyalarla derin birleştirme (`deep_merge`) sağlandı.
   - `.rubik/config.yml` ve `rubik.yml` proje konfigürasyonları otomatik okundu.
2. REPL Komut Güncellemeleri (`lib/rubik/repl/shell.rb`):
   - `!model <provider/name> [--project|--global]` hızlı model geçişi ve otomatik kalıcılık.
   - `!model set <role> <model> [--project|--global]` role özgü model atama ve diske yazma.
   - `!config set <key> <val> [--project|--global]` ve `!config path` komutları.
3. Birim Testleri:
   - `test/unit/test_config_persistence.rb` ile global/proje kalıcılığı ve sonraki oturumlarda hatırlanması doğrulandı.

---

## 🧪 Kabul Kriterleri

- [x] `!model ollama/qwen2.5-coder` veya `!model openai/gpt-4o-mini` komutu çalıştırıldığında ayar `~/.rubik/config.yml` dosyasına yazılır.
- [x] Rubik yeniden başlatıldığında veya başka bir dizinde açıldığında seçilen model hatırlanır.
- [x] `!model set default anthropic/claude-3-7-sonnet --project` denildiğinde ayar sadece o projenin `.rubik/config.yml` dosyasına kaydedilir ve globali ezerek geçerli olur.
- [x] `!config path` komutu global ve proje konfigürasyon dosyası yollarını gösterir.

---

## Bağımlılıklar

- [Plan 01 (Proje İskeleti ve Konfigürasyon)](01-proje-iskeleti-ve-konfigurasyon.md)
- [Plan 02 (REPL Çekirdeği)](02-repl-cekirdegi.md)
- [Plan 17 (Native LLM & Model Yönlendirme)](17-native-tool-calling-ve-model-yonlendirme.md)

---

## Test Kapsamı

- `test/unit/test_config_persistence.rb`:
  - `test_global_config_persistence_and_retention`
  - `test_project_config_overrides_global_config`
  - `test_shell_model_command_auto_persists`
  - `test_shell_config_set_and_paths`
