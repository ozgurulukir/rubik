# 20 — Spatiotemporal Composability ve Kendi Kendini Geliştiren Çalışma Zamanı

**Durum:** ✅ **Tamamlandı** · **Zorluk:** Zor · **Öneri kaynağı:** `AGENTS.md`, §7.6 · **Faz:** 5 (İleri Mimari & Eklentiler)  
**İlgili Planlar:** [14 — Eklenti Sistemi](14-eklenti-sistemi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [Index](index.md)

## Amaç

`AGENTS.md` protokolünde tanımlanan **Uzay-Zamansal Bileşebilirlik (Spatiotemporal Composability)** mimarisini Rubik çekirdeğine kazandırmak:
1. **Zamansal Bileşebilirlik (Revertible Effects):** Çevreye yapılan her yan etkinin (araç kaydı, hook, event dinleyicisi, geçici dosya) tersiyle ($\Omega$ LIFO akümülatörü) eşleştirilmesi ve bileşen kalktığında tam geri alınması.
2. **Uzamsal Bileşebilirlik (Reactive Coeffects):** Eklenti ve araçların bağımlılıklarını (`inject`) açıkça beyan etmesi ve bağımlılıklar sağlandığında reaktif olarak `Pending` → `Active` durumuna geçmesi.
3. **Alt Bağlam İzolasyonu (`ctx.extend()`):** Ajanın kendi ürettiği deneysel araçları veya alt görevleri izole sub-context'lerde koşturması; hata durumunda atomik geri alma (`Atomic Context Rollback`) yapması.

## Tamamlanan Görevler

1. `Rubik::Runtime::Context`:
   - `register_disposable(cleanup_fn)` / `on_dispose`: Yan etkilerin tersini LIFO sırada takip eden akümülatör ($\Omega$).
   - `provide(service_name, service)` / `require(service_name)`: Reaktif coeffect bağımlılık çözümleme ve eksik coeffect hatası (`CoeffectMissingError`).
   - `extend()`: Özyinelemeli (recursive) disposable alt bağlam üretimi.
   - `dispose()`: Tüm birikmiş ters dönüşümleri (inverses) LIFO sırayla çalıştırma.
2. `Rubik::Runtime::Fiber` Durum Makinesi:
   - Durumlar: `Pending` ⟷ `Active` ⟶ `Failed` ⟶ `Disposed`.
   - Coeffect'ler sağlandığında fabrikayı çalıştırıp `Active` yapma; aktivasyon anında hata oluşursa kısmi tersleri anında çalıştırıp atomik geri alma yapma (`:failed`).
3. `Rubik::Runtime::Manager`:
   - Reaktif uzamsal bağdaştırma (`reconcile_all` / `reconcile_fiber`).
   - Sıfır kesintili dinamik araç/eklenti değişimi (`swap_component`).
4. 1.000 İterasyonluk Canlı Sıcak Değişim & Sızıntı Doğrulaması:
   - 1.000 kez arka arkaya tool/eklenti değişim döngüsünde tek bir öksüz dinleyici bırakmadan %100 temiz çalışma kanıtlandı.

## Kabul Kriterleri

- [x] Bir eklenti veya araç kaldırıldığında/yenilendiğinde bellekte hiçbir öksüz dinleyici, açık dosya veya zombi kalmaz (1000 kez arka arkaya yükle-kaldır sızıntısız geçer).
- [x] Aktivasyon sırasında hata fırlatan bir eklenti, o ana kadar yaptığı tüm kısmi kayıtları atomik olarak geri alır (Atomic Context Rollback).
- [x] Ajanın deneysel araç sentezi izole `ctx.extend()` içinde başarıyla doğrulanıp kalıcı runtime'a terfi ettirilir.

## Bağımlılıklar

- [Plan 14 (Eklenti Sistemi)](14-eklenti-sistemi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 01 (İskelet ve Olay Veri Yolu)](01-proje-iskeleti-ve-konfigurasyon.md)
- `AGENTS.md` (Spatiotemporal Composability Protocol)

## Test Kapsamı

- `test/unit/test_spatiotemporal_runtime.rb`: LIFO ters sıra yürütümü, Coeffect gereksinimleri, özyinelemeli alt bağlam temizliği, Fiber reaktif geçişleri, Atomic rollback ve 1.000 iterasyonluk stress reload testleri.
