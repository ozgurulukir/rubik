# Rubik Implementasyon Planları — İndeks

Kaynak: `_proposal/rubik-codingAgent-mainProposal.md` (v1.2)

Planlar **semantik birimlere** ayrılmıştır; her birim bağımsız test edilebilir ve
kendi kabul kriterlerine sahiptir. Numaralandırma yaklaşık olarak **kolaydan zora**
ve **bağımlılık sırasına** göredir.

## Plan Listesi

| # | Plan | Zorluk | Öneri Bölümü | Faz |
| --- | --- | --- | --- | --- |
| 01 | [Proje İskeleti ve Konfigürasyon](01-proje-iskeleti-ve-konfigurasyon.md) | Kolay | §7.6 | 1 |
| 02 | [REPL Çekirdeği ve Komut Ayrıştırıcı](02-repl-cekirdegi.md) | Kolay–Orta | §7.1, §8 | 1 |
| 03 | [Bellek İçi Dosya Tamponu, Snapshot ve Undo](03-dosya-tamponu-snapshot-undo.md) | Orta | §7.1, §9.3 | 1 |
| 04 | [Oturum Loglama, History ve Replay](04-oturum-loglama-replay.md) | Orta | §7.1 | 1 |
| 05 | [Bağlam Motoru: Dosya İndeksi ve Git Durumu](05-baglam-motoru-dosya-indeksi.md) | Orta | §7.2 | 2 |
| 06 | [AST Sembol Tablosu ve Bağımlılık Grafı](06-ast-semantik-indeks.md) | Zor | §7.2 | 2 |
| 07 | [Dil Adaptör Çerçevesi](07-dil-adaptor-cercevesi.md) | Orta | §7.3 | 3 |
| 08 | [Derleyici Çıktısı Ayrıştırma ve Teşhis](08-hata-ayristirma-teshis.md) | Orta–Zor | §7.4, §7.3 | 3 |
| 09 | [LLM Sağlayıcı Soyutlaması](09-llm-saglayici-soyutlamasi.md) | Orta | §7.5 | 2 |
| 10 | [Tool-Calling ve Plan→Act→Verify Orkestrasyonu](10-tool-calling-orkestrasyon.md) | Zor | §7.5, §8 | 2 |
| 11 | [Kendi Kendini Onarma Döngüsü](11-kendi-kendine-onarim.md) | Zor | §7.4 | 4 |
| 12 | [Güvenlik Katmanı: Diff Onayı ve Kritik Dosya Koruması](12-guvenlik-diff-onay.md) | Orta–Zor | §9 | 4 |
| 13 | [Sandbox ve Süreç İzolasyonu](13-sandbox-izolasyon.md) | Zor | §9.1 | 4 |
| 14 | [Eklenti Sistemi](14-eklenti-sistemi.md) | Orta–Zor | §7.6 | 5 |
| 15 | [Benchmark ve Kabul Testleri](15-benchmark-kabul-testleri.md) | Orta | §10 | 5 |

## Bağımlılık Grafı

```text
01 ─┬─ 02 ─── 04
    ├─ 03 ─┬─ 12
    │      └─ 04
    ├─ 05 ─── 06 ─┐
    ├─ 07 ─┬─ 08 ─┼─ 11
    │      ├─ 13  │
    │      └─ 14  │
    └─ 09 ─── 10 ─┴─ 12
                  └─ 11
15 (tüm planlar tamamlandığında)
```

## Önerilen Yürütme Sırası

Paralel çalışmaya uygun iki hat halinde ilerleyin:

- **Hat A (altyapı):** 01 → 02 → 03 → 04 → 05 → 06
- **Hat B (zekâ):** 09 → 07 → 08 → 10 → 11

Sonrasında entegrasyon planları: 12 → 13 → 14 → 15.

## Ortal Kurallar (tüm planlar için geçerli)

- Dil: Ruby 3.3+, test çerçevesi: Minitest (stdlib, ek bağımlılık yok).
- Her modül kendi ad alanında (`Rubik::REPL`, `Rubik::Context`, ...) ve kendi
  dosyasında yaşar; katmanlar arası iletişim olay veri yolu (event bus) ile.
- Tüm harici süreç çağrıları (derleyici, git, LLM HTTP) arayüz arkasında gizlenir;
  testlerde mock'lanır.
- Hiçbir görev diske kalıcı yazma yapamaz; yazma yalnızca `!apply` akışından geçer.
