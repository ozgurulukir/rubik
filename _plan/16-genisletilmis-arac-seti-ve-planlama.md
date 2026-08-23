# 16 — Genişletilmiş Araç Seti ve Planlama Orkestrasyonu

**Zorluk:** Orta–Zor · **Öneri kaynağı:** §7.5, §8 · **Faz:** 2–3 (Geliştirme)  
**İlgili Planlar:** [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [06 — AST İndeks](06-ast-semantik-indeks.md) · [12 — Güvenlik](12-guvenlik-diff-onay.md) · [Index](index.md)

## Amaç

Ajanın çevre ile etkileşimini sadece dosya okuma/yazma ile sınırlandırmayıp; projeyi otonom keşfetmesini sağlayan `list_files`, `search_symbols`, `run_tests` ve onaylı `run_command` araçlarını eklemek; ayrıca `!plan <görev>` komutu ile salt-planlama (dry-run) ve kullanıcı onay akışını inşa etmek.

## Görevler (kolaydan zora)

1. `Rubik::Tools::ListFilesTool`: `Scanner` ve `Index` ile entegre çalışan, filtreleme ve dizin sınırlandırması olan dosya listeleme aracı.
2. `Rubik::Tools::SearchSymbolsTool`: `Rubik::AST::Graph` üzerinden sembol ve çağrı arayan, fonksiyona/sınıfa göre akıllı bağlam getiren araç.
3. `Rubik::Tools::RunTestsTool`: Projede tespit edilen aktif dil adaptörünün `run_tests` metodunu tetikleyen ve yapılandırılmış test çıktılarını döndüren araç.
4. `Rubik::Tools::RunCommandTool`: `Security::Guard` ve `Sandbox::Runner` onayından geçen, salt-okunur veya izinli komutları çalıştıran araç.
5. REPL default tool kayıtçısının genişletilmesi: `REPL::Shell` serbest metin ve planlama döngüsünde tüm bu araçların `Tools::Registry`'ye otomatik kaydedilmesi.
6. `!plan <görev>` Komutu: Görevi LLM'e sadece eylem adımları (Plan) üretmesi için gönderen, üretilen planı ekrana yazıp kullanıcıdan `[y/N]` onayı isteyen, onaylanırsa plan adımlarını uygulayan akış.
7. Adım ve token bütçesi izleme: Her araç çağrısında tüketilen adımların ve token'ların oturum bazında gösterilmesi.

## Kabul Kriterleri

- [ ] Ajan `list_files` ile proje dosyalarını listeler ve sadece ilgili dosyaları okur.
- [ ] `search_symbols` ile fonksiyon çağrı haritasını çıkararak hedeflenen fonksiyonu bulur.
- [ ] `!plan <görev>` komutu çalıştırıldığında diske veya tampona doğrudan yazma yapılmaz; önce plan sunulur.
- [ ] Kullanıcı `y` derse plan adımları tampona uygulanır; `n` derse işlem iptal edilir.

## Bağımlılıklar

- [Plan 10 (Tool-Calling)](10-tool-calling-orkestrasyon.md)
- [Plan 06 (AST Sembol Tablosu)](06-ast-semantik-indeks.md)
- [Plan 07 (Dil Adaptörleri)](07-dil-adaptor-cercevesi.md)
- [Plan 12 (Güvenlik Katmanı)](12-guvenlik-diff-onay.md)

## Test Stratejisi

- Birim: `ListFilesTool`, `SearchSymbolsTool`, `RunTestsTool` ve `RunCommandTool` bağımsız mock ortamında test edilir.
- Entegrasyon: Sahte LLM ile `!plan` komutunun onaylı ve reddedilen akışları simüle edilir.
