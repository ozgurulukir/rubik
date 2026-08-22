# 09 — LLM Sağlayıcı Soyutlaması

**Zorluk:** Orta · **Öneri kaynağı:** §7.5 · **Faz:** 2

## Amaç

Bulut (OpenAI, Anthropic, Gemini) ve yerel (Ollama) modellerin arkasındaki tek
arayüz; `!model` komutu; prompt enjeksiyon korumasının ilk katmanı. Bu planda henüz
tool-calling yoktur (Plan 10) — yalnızca düz metin tamamlama/konuşma.

## Görevler (kolaydan zora)

1. `Rubik::LLM::Provider` sözleşmesi: `complete(messages, opts) -> Response`;
   Response: `{text, usage: {input_tokens, output_tokens}, raw}`.
2. HTTP istemcisi: Net::HTTP (stdlib) tabanlı, timeout'lu, retry'lı (üstel geri
   çekilme, 429/5xx'te maks. 3 deneme) ortak istemci.
3. **Ollama sağlayıcısı** (ilk implementasyon): yerel, anahtar gerektirmez,
   geliştirme sırasında ücretsiz test imkânı.
4. **OpenAI sağlayıcısı** ve **Anthropic sağlayıcısı**: resmi REST şemaları;
   anahtarlar yalnızca ortam değişkenlerinden okunur (`OPENAI_API_KEY` vb.) —
   config dosyasına anahtar yazılması yasaktır.
5. Sağlayıcı/model kayıt defteri + `!model [isim]`: liste gösterme ve geçiş;
   geçersiz modelde mevcut modeller listelenir.
6. Akış (streaming): SSE okuyarak token-token basma (REPL streaming UI'sine besleme);
   akışı desteklemeyen sağlayıcıda düz yanıta düşüş.
7. Prompt enjeksiyon koruması v1: kullanıcı/dosya içeriği özel etiketlere sarılır
   (`<user_input>...</user_input>`); sistem talimatı ayrı rolde gönderilir.
8. Token sayacı: yaklaşık sayaç (kelime+karakter sezgisi) ile usage loglama;
   maliyet takibi için isteğe bağlı fiyat tablosu.

## Kabul Kriterleri

- [ ] Config'te yalnızca sağlayıcı adı + model adı bulunur; asla API anahtarı.
- [ ] Ağ kesikken sağlayıcı çağrısı 30 sn içinde anlaşılır hatayla döner, REPL donmaz.
- [ ] Ollama ve OpenAI arasında `!model` ile geçiş kod değişikliği gerektirmez.

## Bağımlılıklar

- Plan 01 (config: aktif sağlayıcı/model).

## Test Stratejisi

- Birim: mock HTTP sunucusu (WEBrick) ile retry, timeout, hata gövdesi yolları.
- Entegrasyon: CI'da ağ erişimi olmadan yalnızca mock sağlayıcıyla; manuel kabul
  testleri gerçek Ollama/OpenAI'e karşı belgelenir.
- Güvenlik: anahtarın hiçbir log'a/istisna mesajına sızmadığının testi.
