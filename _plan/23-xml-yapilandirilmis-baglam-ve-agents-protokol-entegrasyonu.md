# 23 — XML Tabanlı Yapılandırılmış Bağlam İzolasyonu ve Kural Dosyaları (`AGENTS.md`) Entegrasyonu

**Zorluk:** Orta–Zor · **Öneri kaynağı:** Kullanıcı Yönergesi & `AGENTS.md` (§1, §3) · **Faz:** 5 (Bağlam Mühendisliği & Protokol Entegrasyonu)  
**İlgili Planlar:** [22 — Durumsal Farkındalık](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md) · [20 — Spatiotemporal Composability](20-spatiotemporal-composability-eklenti-dongusu.md) · [05 — Bağlam Motoru](05-baglam-motoru-dosya-indeksi.md) · [Index](index.md)

---

## Amaç

1. **XML Marker Tabanlı Bağlam İzolasyonu:** Modelin sistem yönergelerini, protokol kurallarını, çalışma alanı meta verilerini, REPL komutlarını ve kullanıcı görevini birbirine karıştırmasını (*context bleeding*) engellemek amacıyla açık XML etiketleri (`<protocol>`, `<workspace_status>`, `<repl_commands>`, `<buffer_status>`, `<user_task>`) kullanmak.
2. **Kural ve Protokol Dosyalarının (`AGENTS.md`, `RULES.md`) Otomatik Enjeksiyonu:** Proje kökünde veya `.rubik/` altında bulunan `AGENTS.md` (Spatiotemporal Composability protokolü) ve diğer kural dosyalarını otomatik olarak keşfedip `<protocol path="AGENTS.md">` etiketiyle LLM sistem istemine eklemek.
3. **Dinamik Çalışma Alanı ve Bellek Durumu Bildirimi:** Git dalı, indekslenen dosya sayısı, tespit edilen diller ve tampon (`dirty buffer`) durumunu yapılandırılmış XML formatında modele hazır sunmak.

---

## XML Bağlam Şeması

```xml
<system_context>
  <!-- 1. Protokol ve Proje Kuralları -->
  <protocol source="AGENTS.md">
    # Protocol for Spatiotemporal Composability & Self-Evolving Runtimes
    ...
  </protocol>

  <!-- 2. Çalışma Alanı Durumu -->
  <workspace_status>
    <project_name>rubik</project_name>
    <git_branch>main</git_branch>
    <indexed_files count="125">Ruby, Go, Rust, Zig, C, Python</indexed_files>
  </workspace_status>

  <!-- 3. Bellek Tamponu Durumu -->
  <buffer_status dirty="false">
    <dirty_files count="0"></dirty_files>
    <snapshot_count>3</snapshot_count>
  </buffer_status>

  <!-- 4. Canlı REPL Komutları -->
  <repl_commands>
    <command name="!diff" scope="builtin">Show unapplied buffer changes</command>
    <command name="!undo" scope="builtin">Revert the last snapshot</command>
    <command name="!test" scope="builtin">Run test suite via active adapter</command>
    <command name="!model" scope="builtin">Switch or tune model roles (fast/advanced)</command>
    <command name="!context" scope="builtin">Manage file context index (scan/add)</command>
    <command name="!db_seed" scope="project">Seed test database</command>
  </repl_commands>
</system_context>

<user_task>
  Lütfen auth modülündeki token yenileme mantığını düzelt.
</user_task>
```

---

## Görevler (kolaydan zora)

1. `Rubik::Prompt::ContextBuilder` Modülü:
   - Proje kökünde `AGENTS.md`, `.rubik/AGENTS.md`, `RULES.md`, `CLAUDE.md` arama ve içeriğini `<protocol>` içine sarma.
   - REPL kabuğundan (`Shell`) kayıtlı komutları çekip `<repl_commands>` XML bloğu üretme.
   - `Buffer::Manager` ve `SnapshotStore` durumundan `<buffer_status>` XML bloğu üretme.
   - `Context::Index` özetinden `<workspace_status>` XML bloğu üretme.
2. `Rubik::Orchestrator::Loop` Entegrasyonu:
   - `Loop#run` metodunun Sistem İstemini `ContextBuilder.build_system_prompt(...)` üzerinden derlemesi.
3. Kullanıcı Görevi İzolasyonu:
   - Görev metninin `<user_task>` etiketi içine alınması.
4. Birim ve İzolasyon Testleri:
   - `test/unit/test_structured_context_builder.rb`.

---

## Kabul Kriterleri

- [ ] Projede `AGENTS.md` mevcut olduğunda, dosya içeriği otomatik olarak `<protocol source="AGENTS.md">` etiketiyle bağlama eklenir.
- [ ] Model, sistem istemindeki tüm bileşenleri standart XML etiketleri ile net sınırlarla ayrıştırılmış olarak alır.
- [ ] REPL'de yeni bir dinamik komut (`!db_seed`) eklendiğinde, bir sonraki istemde bu komut `<repl_commands>` listesinde otomatik belirir.
- [ ] Bellek içi tamponda kaydedilmemiş değişiklik olduğunda `<buffer_status dirty="true">` ve dosya isimleri açıkça bildirilir.

---

## Bağımlılıklar

- [Plan 22 (LLM Durumsal Farkındalık)](22-llm-durumsal-farkindalik-ve-geri-bildirim-dongusu.md)
- [Plan 20 (Spatiotemporal Composability)](20-spatiotemporal-composability-eklenti-dongusu.md)
- [Plan 05 (Bağlam Motoru)](05-baglam-motoru-dosya-indeksi.md)
- `AGENTS.md`
