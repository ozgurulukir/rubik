# 31 — Agentic Coding İçin Esnek Adım Bütçesi (Step Budget), Dinamik Genişletme ve Model Yakınsama (Convergence) Mimarisi

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta · **Öneri kaynağı:** Kullanıcı Talebi (Step Budget Exceeded) · **Faz:** 5 (Otonom Ajan & REPL Mimarisi)  
**İlgili Planlar:** [10 — Tool-Calling & Orkestrasyon](10-tool-calling-orkestrasyon.md) · [16 — Genişletilmiş Araç Seti, Plan ve Goal](16-genisletilmis-arac-seti-ve-planlama.md) · [22 — LLM Durumsal Farkındalık](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [25 — Yapılandırma Kalıcılığı](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md) · [CONFIG.md](../CONFIG.md) · [Index](index.md)

---

## 🎯 1. Mevcut Durum Analizi & Problem

Mevcut durumda:
- `Rubik::Orchestrator::Loop` içinde varsayılan adım bütçesi (`max_steps: 15`) ve `!goal` komutunda (`max_steps: 30`) sabit kodlanmıştı (hardcoded).
- Derin agentic coding görevlerinde (kod tabanını tarama, sembolleri arama, birden fazla dosyayı tamponda düzenleme, LSP teşhislerini düzeltme ve testleri koşturma) 15 adım yetersiz kalmakta ve `Max steps budget exceeded (15)` hatasıyla süreç kesintiye uğramaktaydı.
- Adım bütçesi `config.yml` üzerinden yapılandırılamamaktaydı.
- Model adım bütçesinin sonuna yaklaştığında (`step 12 / 15` gibi) durumun farkında olmamakta, bu nedenle toparlanıp (`finish` veya `run_tests`) görevi tamamlayamamaktaydı.

---

## 💡 2. Hedeflenen Çözüm & Mimari Tasarım

```text
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                          AGENTIC STEP BUDGET & CONVERGENCE MİMARİSİ                              │
├─────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                 │
│  1. Config Knobs (agent / orchestrator):                                                        │
│     • agent.max_steps: 40           (Varsayılan interaktif serbest görev bütçesi: 15 -> 40)    │
│     • agent.goal_max_steps: 80      (Otonom !goal döngüsü bütçesi: 30 -> 80)                    │
│     • agent.plan_max_steps: 15      (!plan üretimi bütçesi)                                     │
│     • agent.warn_at_ratio: 0.75     (%75 adıma ulaşıldığında modele yakınsama uyarısı gönderir) │
│                                                                                                 │
│  2. Durumsal Farkındalık & Yakınsama Sinyali (Convergence Signal):                              │
│     • Model bütçenin %75'ine ulaştığında (örn: 30/40), sistem otomatik olarak:                 │
│       "<step_budget current='30' max='40' remaining='10' alert='Budget nearing limit.           │
│        Please begin concluding your work, verify with tests, and call finish.' />"               │
│       enjekte eder.                                                                             │
│                                                                                                 │
│  3. REPL Dinamik Bütçe Genişletme & Etkileşimli Devam Etme:                                     │
│     • Bütçe aşıldığında REPL kullanıcıya sorar: "Adım bütçesine ulaşıldı (40).                  │
│       +20 adım daha devam edilsin mi? [Y/n]"                                                    │
│     • REPL komutu: !steps <sayı> veya !config set agent.max_steps <sayı>                        │
│                                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 3. Yeni Yapılandırma Şeması (`config.yml`)

```yaml
# ------------------------------------------------------------------------------
# 🤖 Agentic Orkestrasyon ve Adım Bütçesi (Agentic Coding Knobs)
# ------------------------------------------------------------------------------
agent:
  # Standart interaktif promptlar için maksimum adım sayısı (Önceki: 15, Yeni: 40)
  max_steps: 40

  # !goal otonom test-geçirme döngüsü için adım sayısı (Önceki: 30, Yeni: 80)
  goal_max_steps: 80

  # !plan plan üretimi adım sayısı
  plan_max_steps: 15

  # Bütçe uyarı eşiği (0.75 = Bütçenin %75'inde model uyarılır)
  warn_at_ratio: 0.75

  # Bütçe aşıldığında etkileşimli REPL'de otomatik devam sorma
  ask_continue_on_limit: true
```

---

## 🛠️ 4. Eklenecek ve Güncellenecek Bileşenler

### A. Yapılandırma Düğmeleri (`lib/rubik/config.rb`)
- [x] `DEFAULT_CONFIG` içine `"agent"` bloğu (`max_steps: 40`, `goal_max_steps: 80`, `plan_max_steps: 15`, `warn_at_ratio: 0.75`, `ask_continue_on_limit: true`) eklenmesi.

### B. Orkestrasyon Döngüsü & Yakınsama Uyarıları (`lib/rubik/orchestrator/loop.rb`)
- [x] `max_steps` değerinin config'den dinamik okunması (varsayılan: 40).
- [x] Döngü içinde `warn_at = (max_steps * 0.75).ceil` eşiğinde modele adım bütçesi uyarısı enjekte edilmesi.
- [x] `extend_budget(extra_steps)` metodu ile çalışan orkestrasyonun bütçesini artırabilme.

### C. REPL Entegrasyonu & `!steps` Komutu (`lib/rubik/repl/shell.rb`)
- [x] `execute_free_text`, `!goal`, `!plan` komutlarının `config.fetch("agent.max_steps", 40)` değerlerini kullanması.
- [x] Limit aşıldığında kullanıcıya devam etme seçeneği (`[Y/n]`) sunulması.
- [x] `!steps <num>` veya `!steps` komutu ile aktif adım bütçesinin sorgulanması / ayarlanması.

---

## 🧪 5. Kabul Kriterleri & Test Senaryoları

- [x] Standart görevler için varsayılan adım bütçesi 40, `!goal` için 80 olarak çalışır.
- [x] `config.set("agent.max_steps", 60)` ile adım bütçesi kolayca değiştirilir ve kalıcı kaydedilir.
- [x] Model bütçenin son çeyreğine girdiğinde durum uyarısı alır.
- [x] `test/unit/test_agent_step_budget.rb` testleri %100 yeşil geçer.
