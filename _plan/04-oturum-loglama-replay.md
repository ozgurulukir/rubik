# 04 — Oturum Loglama, History ve Replay

**Zorluk:** Orta · **Öneri kaynağı:** §7.1 · **Faz:** 1

## Amaç

Tüm REPL girdi/çıktılarının JSONL olarak `~/.rubik/sessions/` altına kaydı;
`!history`, `!session save/load`, `!replay` komutları. Denetlenebilirlik ve
tekrarlanabilirliğin temeli.

## Görevler (kolaydan zora)

1. `Rubik::Session::Recorder`: her etkileşimi `{ts, type, payload}` JSONL satırı
   olarak yazar (type: `input`, `output`, `command`, `event`).
2. Hassas bilgi maskeleme: API anahtarı deseni (`sk-...`, `AKIA...`) log'a yazılmadan
   önce `***MASKED***` ile değiştirilir.
3. Otomatik oturum: REPL başlarken timestamp'lı oturum dosyası açılır; çıkışta kapanır.
4. `!history [n]`: son n girdiyi numaralı listeler (varsayılan 20).
5. `!session save <ad>` / `!session load <ad>`: mevcut oturum dosyasını adla
   kopyalar/sembolik bağlar; `load` yeni oturumu kayıtlı dosyaya devam ettirir.
6. `!replay <oturum_dosyası>`: kayıttaki `input` satırlarını sırayla REPL'e besler.
   LLM yanıtları deterministik olmadığından replay "yaklaşık"tır; bu belgelenir.
7. Replay güvenliği: replay sırasında `!apply` ve `!sh` komutları atlanır
   (onaysız kalıcı etki); atlanan komutlar `[skipped: destructive]` notuyla loglanır.

## Kabul Kriterleri

- [ ] 1000 komutluk oturum JSONL'i hatasız yazılır ve geri okunur.
- [ ] Logda API anahtarı deseni asla düz metin görünmez (test: sahte anahtar besle).
- [ ] `!replay` yalnızca okuma/yazma-tamponu komutlarını uygular; kalıcı etki üretmez.

## Bağımlılıklar

- Plan 02 (REPL döngüsü, hook sistemi — recorder hook'lara bağlanır).

## Test Stratejisi

- Birim: maskeleme regex'leri (pozitif/negatif örnekler), JSONL round-trip.
- Entegrasyon: script modunda oturum koştur → `!replay` ile tekrar koştur →
  girdi sırasının korunduğunu doğrula.
