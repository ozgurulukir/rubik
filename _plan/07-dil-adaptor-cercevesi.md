# 07 — Dil Adaptör Çerçevesi

**Zorluk:** Orta · **Öneri kaynağı:** §7.3 · **Faz:** 3

## Amaç

`BaseAdapter` sözleşmesi ve kompozisyon/strateji deseniyle çok dilli araç zinciri
katmanı. İlk adaptör sırası kolaydan zora: **Ruby → Python → Go → Rust → C → Zig**
(önerinin tersine; çünkü Ruby/Python hızlı sözdizimi kontrolüyle çerçeveyi erken
doğrular, Zig/C en son gelir).

## Görevler (kolaydan zora)

1. `BaseAdapter` sözleşmesi: `check_syntax`, `compile`, `run_tests`, `parse_errors`,
   `format_code`, `dependencies` — hepsi `NotImplementedError`.
2. Adaptör kayıt defteri: dil adı → adaptör sınıfı; uzantı/build-dosyası eşlemesiyle
   otomatik seçim; `rubik.yml` override'ı önceliklidir.
3. Süreç çalıştırıcı (`Rubik::Adapters::Process`): timeout'lu subprocess, stdout/
   stderr yakalama, exit code; tüm adaptörler bunu kullanır (test edilebilirlik).
4. **Ruby adaptörü:** `ruby -c` sözdizimi, `rubocop` lint (varsa), minitest/rspec
   koşturma, `ruby -e` ile format yoksa passthrough.
5. **Python adaptörü:** `python -m py_compile`, `pytest`, `ruff format` (varsa).
6. **Go adaptörü:** `go vet`, `go build ./...`, `go test ./...`, `go fmt`.
7. **Rust adaptörü:** `cargo check`, `cargo test`, `cargo fmt`, `clippy` (varsa).
8. **C adaptörü:** `clang -fsyntax-only` / `zig cc` dry-run, `ctest`/Makefile hedefleri.
9. **Zig adaptörü:** `zig build-exe -fno-emit-bin` dry-run, `zig test`, `zig fmt`.
10. Araç yokluğu yönetimi: ikilik sistemde yoksa adaptör `Unavailable` döner;
    REPL `!status` bunu raporlar ("zig bulunamadı — Zig görevleri devre dışı").

## Kabul Kriterleri

- [ ] Yeni bir dil eklemek = tek dosya + kayıt defterine bir satır (dokümanlanmış).
- [ ] Her adaptör, karşılık gelen ikilik bulunmayan ortamda çökmez, `Unavailable` döner.
- [ ] `!test` / `!lint` / `!format` aktif adaptör üzerinden çalışır ve çıktıyı
      yapılandırılmış sonuç olarak döndürür (`{ok, output, duration}`).

## Bağımlılıklar

- Plan 01 (config), Plan 02 (REPL komutları).

## Test Stratejisi

- Birim: sahte ikilikler (PATH'e konan stub script'ler) ile her adaptörün başarı/
  başarısızlık/araç-yok yolları.
- Entegrasyon: CI'da mevcut araç zincirlerine göre koşullu gerçek çağrılar
  (ör. Ruby+Go her zaman, Zig/Rust varsa).
