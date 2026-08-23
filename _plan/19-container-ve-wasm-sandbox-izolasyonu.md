# 19 — Container (Docker/Podman) ve Wasm Tabanlı Sandbox İzolasyonu

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** §9.1 · **Faz:** 4 (Güvenlik & İzolasyon)  
**İlgili Planlar:** [13 — Sandbox ve İzolasyon](13-sandbox-izolasyon.md) · [12 — Güvenlik Katmanı](12-guvenlik-diff-onay.md) · [Index](index.md)

## Amaç

Ajanın komut çalıştırma (`!sh`, derleme, test ve onarım doğrulama) adımlarını ana makine süreçlerinden tamamen soyutlamak; **Docker/Podman** veya **Wasmtime (Wasm)** container altyapısıyla dosya sistemi, bellek/CPU kaynakları ve ağ erişiminde tam güvenlikli bir izolasyon katmanı sağlamak.

## Tamamlanan Görevler

1. Çoklu Sürücü Mimarisi (`Rubik::Sandbox::Driver`):
   - `ProcessDriver`: Mevcut yerel alt süreç sürücüsü (hızlı, hafif, proxy ağ izolasyonu).
   - `DockerDriver`: Docker daemon üzerinden `--rm`, `-w /workspace`, `-v`, `--memory`, `--cpus`, `--pids-limit 100`, `--network none` argümanlarıyla güvenli container çalıştırma.
   - `PodmanDriver`: Rootless Podman container sürücüsü.
   - `WasmDriver`: WebAssembly ikiliklerini Wasmtime/Wasmer ile `--dir` pre-opened çalışma alanında izole çalıştırma.
2. Sürücü Çözümleyici ve Otomatik Hiyerarşik Seçim (`Driver.best_available`):
   - `preferred: auto` durumunda sistemde `docker` -> `podman` -> `process` sıralamasıyla otomatik algılama ve güvenli fallback.
3. Birleşik Sandbox Cephesi (`Rubik::Sandbox::Runner`):
   - `config.yml` ve `rubik.yml` sandbox ayarları (`sandbox.driver`, `sandbox.image`, `sandbox.memory_limit_mb`, `sandbox.cpus`, `sandbox.allow_network`).
   - `isolation_level` raporlama mekanizması (`container (docker oci)`, `container (podman rootless)`, `wasm / wasi sandbox`, `rlimit+env_proxy`).

## Kabul Kriterleri

- [x] Docker sürücüsü aktifken `rm -rf /` veya ana makine dosyalarına zarar vermeye çalışan komutlar ana makineyi etkilemez.
- [x] Ağ kapalıyken container içinden dış dünyaya yapılan socket çağrıları `--network none` ile kesin olarak engellenir.
- [x] Docker/Podman/Wasm kurulu olmayan sistemlerde `ProcessDriver`'a otomatik ve güvenli fallback yapılır.
- [x] `config.yml` üzerinden sürücü, bellek, CPU ve zaman aşımı limitleri dinamik olarak yapılandırılabilir.

## Bağımlılıklar

- [Plan 13 (Sandbox ve Süreç İzolasyonu)](13-sandbox-izolasyon.md)
- [Plan 12 (Güvenlik Katmanı)](12-guvenlik-diff-onay.md)
- [Plan 01 (Konfigürasyon)](01-proje-iskeleti-ve-konfigurasyon.md)

## Test Kapsamı

- `test/unit/test_sandbox_drivers.rb`: `ProcessDriver`, `DockerDriver`, `PodmanDriver`, `WasmDriver`, `Driver.best_available` çözümleme ve `Runner` konfigürasyon testleri.
- `test/unit/test_sandbox_runner.rb`: Temel süreç izolasyonu ve zaman aşımı doğrulama testleri.
