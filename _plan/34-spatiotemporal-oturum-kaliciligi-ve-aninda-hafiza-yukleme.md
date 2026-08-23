# 📋 Plan 34: Spatiotemporal Oturum Sürekliliği, Sıfır-Token Anında Hafıza Yükleme (`rubik -c`) ve Yapılandırılmış Diyalog Akışı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** ✅ **Tamamlandı** (171/171 Test %100 Yeşil)

---

## 🎯 1. Hedef ve Kapsam

Kullanıcı `rubik -c` (veya `!session resume`) ile önceki bir oturuma devam etmek istediğinde:
1. **Sıfır-Token Anında Hafıza Yükleme (Zero-Token Hydration):** Önceki konuşmaları tekrar LLM'e gönderip API token'ı yakmak yerine, JSONL olay akışındaki kullanıcı girdileri (`user`), asistan yanıtları (`assistant`) ve REPL komutları doğrudan `@conversation_history` içine yüklenmelidir.
2. **Tam Yapılandırılmış Olay Akışı (`Session::Recorder`):** Oturum kütüğüne sadece ham metinler değil; `user_turn`, `tool_call`, `tool_result`, `assistant_response` ve `repl_command` olayları yapılandırılmış olarak işlenmelidir.
3. **Oturum Sürekliliği (Session Continuity):** Resumed edilen oturumda yeni bir kopuk JSONL dosyası açmak yerine aynı oturum kütüğüne ekleme (`append`) yapılmalı ve `parent_session_id` referansı korunmalıdır.
4. **Görsel Başlangıç Özeti:** Oturum devam ettirildiğinde kullanıcıya yüklenen diyalog tur sayısı, son asistan mesajı ve tampon durumu gösterilmelidir.

---

## 🏛️ 2. Yapılacak Teknik Değişiklikler

### A. [`lib/rubik/session/manager.rb`](../lib/rubik/session/manager.rb) & [`lib/rubik/session/replayer.rb`](../lib/rubik/session/replayer.rb)
- `Manager.restore_session`:
  - Oturum dosyasını okuyup `user_turn`, `assistant_response`, `prompt`, `command` olaylarını çıkararak `@shell.conversation_history` dizisine yükler (0 LLM çağrısı ile anında hidrasyon).
  - Oturumun bağlı olduğu `session_file`'ı Shell'in aktif kaydedicisine devrederek oturum sürekliliğini sağlar.
- `Replayer.replay_file`:
  - Yalnızca hata ayıklama ve regresyon testleri için komutları simüle eden bir araç olarak korunur; normal `rubik -c` akışından ayrıştırılır.

### B. [`lib/rubik/session/recorder.rb`](../lib/rubik/session/recorder.rb)
- `record_user_turn(text)`
- `record_assistant_response(text, tokens: nil)`
- `record_tool_call(tool_name, args, call_id)`
- `record_tool_result(tool_name, output, status)`
- `record_repl_command(cmd, output)`
- `switch_session_file(new_path)` desteği

### C. [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb)
- `resume_session(id)` metodunu güncelleme:
  - Hafızayı anında yükler.
  - `@recorder`'ı o oturum dosyasına bağlar.
  - Kullanıcıya temiz bir oturum devam özeti yazdırır.
- `execute_free_text`, `!goal`, `!plan`, `execute_command` akışlarında yapılandırılmış `record_*` çağrılarını tetikler.

### D. [`bin/rubik`](../bin/rubik)
- `rubik -c` bayrağı ile başlatıldığında son oturumu anında yükleyip hazır duruma getirir.

---

## 🧪 3. Test ve Doğrulama Planı

- `test/unit/test_session_continuity.rb`:
  - Oturum kaydetme ve `restore_session` ile `@conversation_history`'nin anında yüklenmesi (0 API çağrısı).
  - `rubik -c` senaryosunda çok turlu diyalogun kaldığı yerden sorunsuz devam etmesi.
  - Oturum dosyasının kesintisiz `append` edilmesi.
  - Tüm birim testlerin %100 yeşil geçmesi.
