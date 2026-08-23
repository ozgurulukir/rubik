# 27 — Tampon Kirli Durum Hatırlatıcı (Dirty Buffer Reminder), Model Auto-Apply ve Akıllı Eşzamanlama Sistemi

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Kolay–Orta · **Öneri kaynağı:** Kullanıcı Geri Bildirimi · **Faz:** 5 (Kullanıcı Deneyimi & Güvenlik)  
**İlgili Planlar:** [03 — Bellek İçi Dosya Tamponu](03-dosya-tamponu-snapshot-undo.md) · [02 — REPL Çekirdeği](02-repl-cekirdegi.md) · [10 — Tool-Calling Orkestrasyonu](10-tool-calling-orkestrasyon.md) · [12 — Güvenlik Katmanı ve Diff Onayı](12-guvenlik-diff-onay.md) · [23 — XML Yapılandırılmış Bağlam](23-xml-yapilandirilmis-baglam-ve-agents-protokol-entegrasyonu.md) · [25 — Yapılandırma Kalıcılığı](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) · [Index](index.md)

---

## 🔍 Tespit Edilen Problem & İhtiyaç

Rubik'in bellek içi dosya tamponu (`Rubik::Buffer::Manager`), diske dokunmadan önce sanal ortamda güvenli düzenleme ve sınırsız geri alma (`undo`) sunar.

Ancak hem insan kullanıcılar hem de otonom modeller (`LLM`), art arda kod düzenlemeleri yaparken **`!apply` çalıştırmayı unutabilmektedir**. Bu durum şu sorunlara yol açar:

1. **Test ve Kabuk Komutu Uyuşmazlığı:** `!test`, `!lint` veya `!sh` araçları diskteki gerçek dosyaları çalıştırır; tampon diske yazılmadığında testler eski kod üzerinden koşar ve yanıltıcı sonuçlar üretir.
2. **Otonom Ajan Akışının Tıkanması:** Model bir dosyayı düzenleyip ardından test koştuğunda, testin diskteki eski kodu test ettiğini fark edemeyip kendini sonsuz düzeltme döngüsüne sokabilir.
3. **Çıkışta Kayıp Riski:** REPL'den çıkarken (`exit` / `Ctrl+D`) tamponda bekleyen değişikliklerin fark edilmemesi.

---

## 🎯 Çözüm Mimarisi & Yetenekler

```text
┌────────────────────────────────────────────────────────────────────────┐
│               RUBIK AKILLI TAMPON & AUTO-APPLY MİMARİSİ                │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  1. Model Tarafından Auto-Apply (Programmatic Tool & Auto-Flush)       │
│     • apply_buffer native aracı (Model gerektiğinde diske yazar)       │
│     • Config: buffer.auto_apply = on_test | on_finish | always | manual│
│                                                                        │
│  2. REPL Prompt Göstergesi (Visual Ping)                              │
│     rubik (my_project) [main] [DIRTY: 2 files ✎] >                    │
│                                                                        │
│  3. Disk Eşzamanlama Uyarısı (Pre-Execution Sync Ping)                 │
│     !test / !sh öncesi (eğer manual moddaysa):                         │
│     "⚠️ Diskte uygulanmamış 2 değişiklik var. Diske yazılsın mı? [Y/n]"│
│                                                                        │
│  4. Periyodik REPL Hatırlatıcı (Turn-based Reminder)                  │
│     3 tur boyunca unapplied kalınca:                                   │
│     "💡 Hatırlatma: 2 dosya tamponda bekliyor (!diff / !apply)"        │
│                                                                        │
│  5. Güvenli Çıkış Koruması (Exit Guard Interceptor)                   │
│     !quit / !exit anında:                                              │
│     "Uygulanmamış değişiklikler var: Kaydet [y], At [d], İptal [c]"    │
│                                                                        │
│  6. LLM XML Bağlam Uyarısı (Model Awareness Directive)                │
│     <buffer_status dirty="true" unapplied_files="lib/a.rb">            │
│       ⚠️ Notice: External test/shell tools execute files from disk.    │
│       Use 'apply_buffer' or run '!apply' before running disk tests.    │
│     </buffer_status>                                                   │
└────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ Yapılandırma Düğmeleri (Config Knobs)

Kullanıcılar veya modeller `~/.rubik/config.yml` ya da `.rubik/config.yml` üzerinden ayarları yönetebilir:

```yaml
buffer:
  # Auto-Apply Modları:
  # - manual    : Yalnızca açık !apply veya apply_buffer çağrısıyla diske yazar (varsayılan)
  # - on_test   : !test, !lint veya run_command öncesinde tamponu otomatik diske yazar
  # - on_finish : Görev başarıyla tamamlandığında (finish aracı) otomatik diske yazar
  # - always    : Her write_file, replace_file işleminden sonra anında diske yazar
  auto_apply: on_test

  # Modelin apply_buffer aracını doğrudan çağırma izni
  model_can_apply: true

  # Görsel ve etkileşimli hatırlatıcılar
  prompt_indicator: true      # Prompt'ta [DIRTY: N files ✎] gösterimi
  exit_guard: true            # Çıkışta sorma
  reminder_interval: 3        # N tur sonra nazik hatırlatma (0 = kapalı)
```

---

## 📋 Tamamlanan Görevler

1. **`apply_buffer` Native Aracının Eklenmesi (`lib/rubik/tools/builtins.rb`):**
   - Modelin ihtiyaç duyduğunda tampon değişikliklerini tek hamlede diske yazabilmesini sağlayan native tool (`risk: :write`).
2. **Orkestrasyon & Pre-Execution Auto-Apply Mantığı (`lib/rubik/orchestrator/loop.rb`):**
   - `run_command` veya test çalıştırma adımlarından önce `config.fetch("buffer.auto_apply")` kontrolü:
     - `on_test` / `always` ise otomatik `buffer_manager.apply!` çalıştırılır.
   - `finish` aracında `on_finish` ise otomatik kaydedilir.
3. **REPL Hızlı Komutu (`lib/rubik/repl/shell.rb`):**
   - `!autoapply [manual|on_test|on_finish|always]` komutu (ayarı otomatik diske kaydeder).
4. **Prompt Rozeti & Çıkış Koruması (`Shell#prompt` & `Shell#stop`):**
   - Prompt'ta `[DIRTY: N files ✎]` görsel rozeti.
   - Çıkışta kullanıcıya unapplied uyarı gösterimi.
5. **Periyodik Hatırlatıcı Sayaç (`@dirty_turns`):**
   - REPL içinde N komut boyunca tampon kirli kalırsa nazik ipucu yazdırma.
6. **XML Bağlam Güncellemesi (`lib/rubik/prompt/context_builder.rb`):**
   - `<buffer_status>` bloğu içine `auto_apply` modu ve `apply_buffer` yönlendirmesi eklendi.
7. **Birim Testleri (`test/unit/test_buffer_reminder_and_auto_apply.rb`):**
   - 7 test, 37 assertion ile tüm senaryolar doğrulandı.

---

## 🧪 Kabul Kriterleri

- [x] `apply_buffer` native aracı ile model tamponu diske uygulayabilir.
- [x] `buffer.auto_apply: on_test` iken test veya shell komutu çağrıldığında tampon otomatik olarak diske yazılır.
- [x] `buffer.auto_apply: on_finish` iken görev bittiğinde değişiklikler otomatik uygulanır.
- [x] `!autoapply on_test` komutu ile mod çalışma anında değiştirilip diske kaydedilebilir.
- [x] REPL prompt'u tampon kirli olduğunda `[DIRTY: N files ✎]` şeklinde güncellenir.
- [x] Çıkış anında kaydedilmemiş değişiklik varsa uyarı verilir.
- [x] Tüm birim testleri yeşil geçer (122 runs, 625 assertions).
