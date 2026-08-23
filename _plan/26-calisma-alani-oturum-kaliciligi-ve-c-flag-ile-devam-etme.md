# 26 — Çalışma Alanı Oturum Kalıcılığı (Workspace Session Persistence), Oturum Geri Yükleme ve `-c` CLI Bayrağı ile Devam Etme

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Kolay–Orta · **Öneri kaynağı:** Kullanıcı Talebi · **Faz:** 5 (Kullanıcı Deneyimi & Oturum Yönetimi)  
**İlgili Planlar:** [04 — Oturum Loglama ve Replay](04-oturum-loglama-replay.md) · [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [25 — Yapılandırma Kalıcılığı](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) · [Index](index.md)

---

## 🔍 Amaç ve İhtiyaç

Kullanıcı Rubik ile bir projede çalıştıktan sonra çıkış yapıp (`exit`) daha sonra geri döndüğünde, önceki konuşma bağlamını, bellek tamponu durumunu ve oturum geçmişini **kaldığı yerden kesintisiz devam ettirebilmelidir** (`rubik -c` veya `rubik --continue`).

1. **Çalışma Alanına Özel Oturum Depolama:** Her projenin oturumları `.rubik/sessions/` altında zaman damgalı JSONL olarak saklanır.
2. **CLI `-c` / `--continue` Desteği:**
   - `rubik -c`: Mevcut repodaki en son kaydedilmiş oturumu otomatik bulur ve geri yükleyerek başlatır.
   - `rubik -c <session_id>`: Belirli bir geçmiş oturumu açar.
   - `rubik --list-sessions`: Projedeki geçmiş oturumları özetler.
3. **REPL İçi `!session` Komutu:**
   - `!session list`: Çalışma alanındaki tüm oturumları listeler (Tarih, Olay Sayısı, Kapsam, Son İstek).
   - `!session resume [id]`: Çalışma anında geçmiş bir oturumu yükler.
   - `!session info`: Aktif oturum dosyası ve istatistiklerini gösterir.

---

## 🏛️ Mimari Tasarım

```text
┌─────────────────────────────────────────────────────────────┐
│                       CLI BAŞLATMA                          │
├─────────────────────────────────────────────────────────────┤
│ $ rubik -c           -> En son oturumu otomatik yükler      │
│ $ rubik -c 20260823  -> Belirtilen oturumu yükler           │
│ $ rubik --list-sessions -> Geçmiş oturumları listeler       │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│               Rubik::Session::Manager                       │
├─────────────────────────────────────────────────────────────┤
│ • find_latest_session(root_dir, home_dir, exclude_file:)    │
│ • list_sessions(root_dir, home_dir)                         │
│ • find_session(identifier, root_dir, home_dir)              │
│ • restore_session(shell, session_file)                      │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Rubik::REPL::Shell                          │
├─────────────────────────────────────────────────────────────┤
│ 1. Geçmiş komut ve girdileri replay/tarihçeye yükler.       │
│ 2. Prompt ve tamponu hazırlar.                              │
│ 3. "[Rubik] Resumed session: session_20260823_183000.jsonl" │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Tamamlanan Görevler

1. `Rubik::Session::Manager` Modülü (`lib/rubik/session/manager.rb`):
   - Proje içi `.rubik/sessions/` ve global fallback `~/.rubik/sessions/` dizinlerini yönetir.
   - `latest_session(root_dir, home_dir, exclude_file:)`: En son güncellenen `.jsonl` oturum dosyasını tespit eder (aktif oturumu hariç tutar).
   - `list_sessions(root_dir, home_dir)`: Oturum meta verilerini (ID, dosya adı, tarih, olay sayısı, kapsam, son istem) ayıklar.
   - `restore_session(shell, file_path)`: Oturumdaki olayları `Replayer` ile güvenli şekilde yükler ve tarihçeyi bağlar.
2. `Rubik::Session::Recorder` & `Replayer` İyileştirmeleri:
   - `Recorder`: Mikro-saniye çözünürlüklü benzersiz dosya adları (`session_YYYYMMDD_HHMMSS_PID_MS.jsonl`) ve proje `.rubik/sessions` desteği.
   - `Replayer`: Bellek içine satırları önceden çekerek (`readlines`) sonsuz döngüleri engelledi ve `@replaying` koruması getirdi.
3. CLI Argüman Ayrıştırma (`bin/rubik`):
   - `-c`, `--continue [SESSION_ID]` parametresi ile en son oturumu kaldığı yerden başlatma.
   - `--list-sessions` parametresi ile kayıtlı oturumları terminale listeleme.
4. REPL Komut Entegrasyonu (`lib/rubik/repl/shell.rb`):
   - `!session` / `!session list` / `!session resume [id]` / `!session info` komutları.
   - `resume_session(identifier = :latest)` metodu.
5. Birim ve CLI Entegrasyon Testleri:
   - `test/unit/test_session_persistence_and_resume.rb` (4 test, 18 assertion).

---

## 🧪 Kabul Kriterleri

- [x] Projede komutlar ve istemler çalıştırıldığında oturum `.rubik/sessions/` altına kaydedilir.
- [x] `rubik -c` ile başlatıldığında son oturum otomatik algılanır ve önceki girdiler/komutlar geri yüklenir.
- [x] `rubik --list-sessions` çalışma alanındaki tüm geçmiş oturumları tarih ve olay sayısıyla listeler.
- [x] `!session list` ve `!session resume <id>` komutları REPL içinden geçmiş oturumu yükler.

---

## Bağımlılıklar

- [Plan 04 (Oturum Loglama ve Replay)](04-oturum-loglama-replay.md)
- [Plan 02 (REPL Çekirdeği)](02-repl-cekirdegi.md)
- [Plan 25 (Yapılandırma Kalıcılığı)](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md)

---

## Test Kapsamı

- `test/unit/test_session_persistence_and_resume.rb`:
  - `test_recorder_saves_to_project_sessions_directory`
  - `test_session_manager_lists_and_finds_latest_session`
  - `test_shell_resume_session_replays_events`
  - `test_session_repl_command`
