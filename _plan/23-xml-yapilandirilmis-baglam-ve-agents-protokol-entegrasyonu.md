# 23 — XML Yapılandırılmış Bağlam, AGENTS.md Protokolü ve İki Yönlü Stream Entegrasyonu

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§1, §3) · **Faz:** 5 (Bağlam Mühendisliği & Stream Entegrasyonu)  
**İlgili Planlar:** [22 — Durumsal Farkındalık](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [04 — Oturum ve Replay](04-oturum-loglama-replay.md) · [Index](index.md)

---

## Amaç

1. **XML Marker Tabanlı Bağlam İzolasyonu:** Modelin sistem yönergelerini, protokol kurallarını, çalışma alanı meta verilerini, REPL komutlarını ve kullanıcı görevini birbirine karıştırmasını (*context bleeding*) engellemek amacıyla standart XML etiketleri (`<protocol>`, `<workspace_status>`, `<repl_commands>`, `<buffer_status>`, `<user_task>`) kullanmak.
2. **Kural ve Protokol Dosyalarının (`AGENTS.md`, `RULES.md`) Otomatik Enjeksiyonu:** Proje kökünde veya `.rubik/` altında bulunan `AGENTS.md` (Spatiotemporal Composability protokolü) ve diğer kural dosyalarını otomatik olarak keşfedip `<protocol path="AGENTS.md">` etiketiyle LLM sistem istemine eklemek.
3. **İki Yönlü Akan Akış (Bidirectional Streaming) & Bütünleşik Mesaj Geçmişi:**
   - **Girdi Akışı:** Tek satır, çok satırlı heredoc (`<<EOF`) ve UNIX pipe girdilerinin `<user_task>` içinde kronolojik akışa eklenmesi.
   - **Çıktı / Asistan Akışı:** Modelin ürettiği metin tokenlarının, `tool_calls` adımlarının ve araç çalıştırma çıktılarının anlık olarak terminale ve `@history` zincirine kesintisiz akması.
   - **Oturum Transcript Bütünlüğü:** Tüm sistem XML bağlamı, kullanıcı istekleri ve asistan akışının `Session::Recorder` JSONL kayıtlarıyla birebir eşleşmesi.

---

## Tamamlanan Görevler

1. `Rubik::Prompt::ContextBuilder` Modülü (`lib/rubik/prompt/context_builder.rb`):
   - `find_protocol_files` ve `build_protocol_xml`: Projede `AGENTS.md`, `RULES.md`, `CLAUDE.md` varlığını arayıp `<protocol source="...">` içinde XML'e dönüştürme.
   - `build_workspace_xml`: Proje adı, git dalı ve indekslenen dil dağılımını içeren `<workspace_status>` bloğu.
   - `build_buffer_xml`: Değişen tampon dosyalarını ve snapshot sayısını bildiren `<buffer_status dirty="...">` bloğu.
   - `build_commands_xml`: REPL kabuğunda aktif tüm komutları derleyen `<repl_commands>` bloğu.
   - `build_system_prompt`: İstenen mod (`default`, `goal`, `plan`) ve araç şemalarıyla eksiksiz `<system_context>` bloğu.
   - `format_user_task`: Kullanıcı görevini `<user_task>` etiketine sarma.
2. `Rubik::Orchestrator::Loop` ve `Rubik::REPL::Shell` Entegrasyonu:
   - Tüm REPL komutlarında (`!plan`, `!goal`, serbest metin) `ContextBuilder` ile dinamik XML bağlam derleme.
   - `on_step` geri bildirimleri ile araç çağırma ve doğrulama sonuçlarının anlık akması.

---

## Kabul Kriterleri

- [x] Projede `AGENTS.md` mevcut olduğunda, dosya içeriği otomatik olarak `<protocol source="AGENTS.md">` etiketiyle bağlama eklenir.
- [x] Model, sistem istemindeki tüm bileşenleri standart XML etiketleri ile net sınırlarla ayrıştırılmış olarak alır.
- [x] REPL'de yeni bir dinamik komut (`!db_seed`) eklendiğinde, bir sonraki istemde bu komut `<repl_commands>` listesinde otomatik belirir.
- [x] Kullanıcı mesajları (`<user_task>`), asistan adımları ve araç sonuçları tek bir bütünleşik kronolojik akış olarak işlenir.

---

## Bağımlılıklar

- [Plan 22 (LLM Durumsal Farkındalık)](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md)
- [Plan 20 (Spatiotemporal Composability)](20-spatiotemporal-composability-eklenti-dongusu.md)
- [Plan 04 (Oturum Loglama ve Replay)](04-oturum-loglama-replay.md)
- `AGENTS.md`

---

## Test Kapsamı

- `test/unit/test_structured_context_builder.rb`: Protocol arama/XML derleme, workspace durumu, temiz ve kirli bellek tamponu XML dökümü, REPL komutları XML dökümü, sistem istemi ve kullanıcı görevi şablonları, `Loop` entegrasyon testleri.
