# 12 — Güvenlik Katmanı: Diff Onayı ve Kritik Dosya Koruması

**Zorluk:** Orta–Zor · **Öneri kaynağı:** §9.2–9.5 · **Faz:** 4

## Amaç

Güvenlik ilkelerinin merkezi uygulaması: kritik dosya koruması, risk değerlendirme,
denetim logu (`~/.rubik/audit.log`) ve üretilen kodda tehlikeli desen taraması.

## Görevler (kolaydan zora)

1. Kritik yol desenleri: `.git/**`, `.env*`, `secrets.*`, `*.pem`, `*.key`,
   `id_rsa*`; varsayılan liste + `rubik.yml` ile ekleme (çıkarma yok — sadece
   genişletme).
2. Yazma kapısı: tüm tampon yazmaları tek noktadan geçer; kritik desene denk gelen
   yazma `BlockedWrite` hatası döner; aşım yalnızca açık `y/n` onayıyla mümkün.
3. Okuma kısıtı: `!context add` ile taranan kapsam dışındaki hassas dosyalar LLM
   bağlamına girmez (bağlam seçici Plan 06 ile entegre filtre).
4. Tehlikeli desen tarayıcı: üretilen kod/komutlarda `rm -rf /`, `curl | sh`,
   bilinen ağ dışa açılma desenleri; eşleşme → yüksek risk → ek kullanıcı onayı.
5. Komut risk sınıflandırma: beyaz liste (derleyiciler, test çalıştırıcılar) = düşük;
   bilinmeyen ikilik = orta (onay); ağ erişimi/deseni eşleşen = yüksek (açık onay +
   audit).
6. Denetim logu: her komut, LLM isteği (istek metni maskelenmiş), araç çağrısı ve
   sonucu JSON olarak `~/.rubik/audit.log`'a; Plan 04 maskeleme kuralları paylaşılır.
7. Prompt enjeksiyon savunması v2: dosya içeriği etiketlenir; sistem talimatını
   taklit eden desenler (`ignore previous instructions` vb.) bağlam temizleyiciden
   geçirilir; model çıktısında talimat benzeri komut varsa insan onayına düşer.

## Kabul Kriterleri

- [ ] Red-team testleri: ajan `.env`'e yazamaz, `rm -rf /` çalıştıramaz, bağlama
      dahil edilmemiş secret dosyasının içeriği hiçbir LLM isteğine gitmez.
- [ ] Her kalıcı etki (`!apply`, onaylı komut) audit.log'da izlenebilir.
- [ ] Audit log'da API anahtarı/secret deseni geçmez (otomatik tarama testi).

## Bağımlılıklar

- Plan 03 (tampon/yazma noktası), Plan 10 (araç çağrıları), Plan 04 (maskeleme).

## Test Stratejisi

- Birim: desen eşleştirme tabloları (pozitif/negatif örnekler), path traversal
  saldırı vektörleri (`../../`, symlink takibi).
- Entegrasyon: sahte LLM'in kasıtlı olarak zararlı araç çağrısı yaptığı saldırı
  senaryoları — hepsi bloke olmalı.
