# 16 — Genişletilmiş Araç Seti, Planlama ve Otonom Hedef Orkestrasyonu

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Orta–Zor · **Öneri kaynağı:** §7.5, §8 · **Faz:** 2–3 (Geliştirme)  
**İlgili Planlar:** [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [06 — AST İndeks](06-ast-semantik-indeks.md) · [12 — Güvenlik](12-guvenlik-diff-onay.md) · [Index](index.md)

## Amaç

Ajanın çevre ile etkileşimini sadece dosya okuma/yazma ile sınırlandırmayıp; projeyi otonom keşfetmesini sağlayan `list_files`, `search_symbols`, `run_tests` ve onaylı `run_command` araçlarını eklemek; SSoT (Single Source of Truth) araç kayıt mekanizması kurmak; ayrıca `!plan <görev>` (dry-run planlama) ve `!goal <hedef>` (otonom çok adımlı hedef icrası) komutlarını REPL kabuğuna kazandırmak.

## Tamamlanan Görevler

1. `Rubik::Tools::ListFilesTool`: `Scanner` ve `Index` ile entegre çalışan, filtreleme ve dizin sınırlandırması olan dosya listeleme aracı eklendi.
2. `Rubik::Tools::SearchSymbolsTool`: `Rubik::AST::Graph` üzerinden sembol ve çağrı arayan, fonksiyona/sınıfa göre akıllı bağlam getiren araç eklendi.
3. `Rubik::Tools::RunTestsTool`: Projede tespit edilen aktif dil adaptörünün `run_tests` metodunu tetikleyen ve yapılandırılmış test çıktılarını döndüren araç eklendi.
4. `Rubik::Tools::RunCommandTool`: `Security::Guard` ve `Sandbox::Runner` onayından geçen, güvenli komutları çalıştıran araç eklendi.
5. SSoT Araç Kayıtçısı (`Rubik::Tools::Registry.build_default`): DRY ve SSoT prensiplerine uygun olarak tüm varsayılan araçları tek bir fabrikadan kuran merkezi metot oluşturuldu.
6. `!plan <görev>` Komutu: Görevi LLM'e sadece eylem adımları (Plan) üretmesi için gönderen, üretilen planı ekrana yazıp kullanıcıdan `[y/N]` onayı isteyen, onaylanırsa plan adımlarını uygulayan akış eklendi.
7. `!goal <hedef>` Komutu: Yüksek bütçeli (30 adım) otonom döngü kurarak araçları sırayla çalıştıran, testleri koşturan ve hedef doğrulanana kadar süreci yöneten komut eklendi.
8. Adım ve token bütçesi izleme: Her araç çağrısında tüketilen adımların ve token'ların (`@total_tokens`) takip edilmesi ve `on_step` callback ile gerçek zamanlı akış sağlanması.

## Kabul Kriterleri

- [x] Ajan `list_files` ile proje dosyalarını listeler ve sadece ilgili dosyaları okur.
- [x] `search_symbols` ile fonksiyon çağrı haritasını çıkararak hedeflenen sembolü bulur.
- [x] `!plan <görev>` komutu çalıştırıldığında diske veya tampona doğrudan yazma yapılmaz; önce plan sunulur.
- [x] Kullanıcı `y` derse plan adımları tampona uygulanır; `n` derse işlem iptal edilir.
- [x] `!goal <hedef>` komutu çok adımlı otonom akışta araçları işletip doğrulamayı tamamlar.

## Bağımlılıklar

- [Plan 10 (Tool-Calling)](10-tool-calling-orkestrasyon.md)
- [Plan 06 (AST Sembol Tablosu)](06-ast-semantik-indeks.md)
- [Plan 07 (Dil Adaptörleri)](07-dil-adaptor-cercevesi.md)
- [Plan 12 (Güvenlik Katmanı)](12-guvenlik-diff-onay.md)

## Test Kapsamı

- `test/unit/test_expanded_tools.rb`: `ListFilesTool`, `SearchSymbolsTool`, `RunTestsTool`, `RunCommandTool` ve `Registry.build_default` birim testleri.
- `test/unit/test_plan_and_goal.rb`: `!plan` ve `!goal` komutlarının sahte LLM ile uçtan uca senaryo testleri.
