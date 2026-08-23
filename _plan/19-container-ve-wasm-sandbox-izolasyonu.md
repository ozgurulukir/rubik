# 19 — Container (Docker/Podman) ve Wasm Tabanlı Sandbox İzolasyonu

**Zorluk:** Zor · **Öneri kaynağı:** §9.1 · **Faz:** 4 (Güvenlik & İzolasyon)  
**İlgili Planlar:** [13 — Sandbox ve İzolasyon](13-sandbox-izolasyon.md) · [12 — Güvenlik Katmanı](12-guvenlik-diff-onay.md) · [Index](index.md)

## Amaç

Ajanın komut çalıştırma (`!sh`, derleme, test ve onarım doğrulama) adımlarını ana makine süreçlerinden tamamen soyutlamak; **Docker/Podman** veya **Wasmtime (Wasm)** container altyapısıyla dosya sistemi, bellek/CPU kaynakları ve ağ erişiminde tam güvenlikli bir izolasyon katmanı sağlamak.

## Görevler (kolaydan zora)

1. Çoklu Sürücü Mimarisi (`Rubik::Sandbox::Driver`):
   - `ProcessDriver`: Mevcut yerel alt süreç sürücüsü (hızlı, hafif, temel RLIMIT kısıtlı).
   - `DockerDriver`: Docker daemon üzerinden izole container başlatma.
   - `PodmanDriver`: Rootless Podman container sürücüsü.
   - `WasmDriver`: WebAssembly ikiliklerini Wasmtime ile çalıştırma.
2. Container Yaşam Döngüsü ve Bağlama (Mount) Politikaları:
   - Proje kökü container içine `:ro` (salt-okunur) veya kontrollü bind-mount ile bağlanır.
   - `/tmp` ve derleme çıktıları için container içinde geçici tmpfs alanları açılır.
   - Container süresi bitince otomatik yok edilir (`--rm`).
3. Ağ İzolasyonu Politikası:
   - Varsayılan: `--network none` (tüm dış ağ erişimi engellenir).
   - Kullanıcı `!config set network.allow true` dediğinde kontrollü köprü ağına geçilir.
4. Kaynak Kısıtlama (cgroups / RLIMIT):
   - CPU sınırı (ör. `--cpus 1.5`), RAM sınırı (ör. `--memory 1024m`), pids sınırı (fork bomb koruması).
5. Konfigürasyon Entegrasyonu:
   - `rubik.yml` içinde `sandbox.driver: "docker"`, `sandbox.image: "rubik-runner:latest"`, `sandbox.timeout: 30` ayarları.

## Kabul Kriterleri

- [ ] Docker sürücüsü aktifken `rm -rf /` veya ana makine dosyalarına zarar vermeye çalışan komutlar ana makineyi etkilemez.
- [ ] Ağ kapalıyken container içinden dış dünyaya yapılan curl/ping/socket çağrıları kesin olarak başarısız olur.
- [ ] Docker kurulu olmayan sistemlerde `ProcessDriver`'a otomatik ve güvenli fallback yapılır.

## Bağımlılıklar

- [Plan 13 (Sandbox ve Süreç İzolasyonu)](13-sandbox-izolasyon.md)
- [Plan 12 (Güvenlik Katmanı)](12-guvenlik-diff-onay.md)
- [Plan 01 (Konfigürasyon)](01-proje-iskeleti-ve-konfigurasyon.md)

## Test Stratejisi

- Birim: Sürücü arabirimi, container komut argümanı oluşturucular (`docker run ...`).
- Entegrasyon: Docker daemon varlığında test container'ında kaynak ve ağ izolasyon testleri.
