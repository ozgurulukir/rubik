# 14 — Eklenti Sistemi

**Zorluk:** Orta–Zor · **Öneri kaynağı:** §7.6 · **Faz:** 5

## Amaç

Ruby gem tabanlı eklenti mimarisi: yeni dil adaptörleri, REPL komutları, doğrulama
kuralları ve LLM sağlayıcıları eklenebilsin. `rubik.yml` standardı ve komut takma
adları da bu planda tamamlanır.

## Görevler (kolaydan zora)

1. `rubik.yml` şeması: dil adaptör seçimi, test komutları, yasaklı desenler,
   model tercihi, onarım deneme sayısı, bağlam include/exclude. JSON Schema ile
   tanımlanır; okuma sırasında doğrulanır (hatalı anahtar → uyarı, çökme değil).
2. Küresel + proje config birleştirme: `~/.rubik/config.yml` varsayılanlar,
   `rubik.yml` override; `!config get/set <anahtar> <değer>` çalışma anında.
3. Komut takma adları: kullanıcı tanımlı kısayollar (`rt` → `!test`);
   döngüsel takma ad tespiti.
4. Eklenti sözleşmesi: gem, `Rubik.register { |ctx| ... }` bloğuyla adaptör/komut/
   hook/sağlayıcı kaydeder; kayıt sırası deterministik (gem adına göre alfabetik).
5. Eklenti yükleme: `rubik.yml`'de listelenen gem'ler `require` edilir; yükleme
   hatası tek eklentiyi devre dışı bırakır, diğerlerini etkilemez.
6. İzolasyon: eklenti kendi ad alanında çalışır; çekirdek sınıfları monkey-patch
   etmesi engellenmez ama uyarılır (pragmatik yaklaşım, belgelenir).
7. Örnek eklenti (`rubik-plugin-example`): yeni bir `!hello` komutu + sahte dil
   adaptörü — dokümantasyonun canlı örneği.

## Kabul Kriterleri

- [ ] Örnek eklenti gem'i kurulup `rubik.yml`'ye eklenince `!hello` çalışır ve
      sahte adaptör kayıt defterinde görünür.
- [ ] Bozuk bir eklenti (yüklemede exception) diğer eklentileri ve çekirdeği
      etkilemez; hata loglanır ve REPL başlar.
- [ ] `rubik.yml` bilinmeyen anahtarlarla yüklenir, uyarı verir, çökmez.

## Bağımlılıklar

- Plan 07 (adaptör kayıt defteri), Plan 02 (komut tablosu), Plan 01 (config).

## Test Stratejisi

- Birim: config birleştirme/şema doğrulama, takma ad çözümleme (döngü dahil).
- Entegrasyon: test gem'i fixture olarak repo içinde inşa edilir (`gem build`) ve
  gerçek yükleme akışından geçirilir.
