# 20 — Spatiotemporal Composability ve Kendi Kendini Geliştiren Çalışma Zamanı

**Zorluk:** Zor · **Öneri kaynağı:** `AGENTS.md`, §7.6 · **Faz:** 5 (İleri Mimari & Eklentiler)  
**İlgili Planlar:** [14 — Eklenti Sistemi](14-eklenti-sistemi.md) · [10 — Tool-Calling](10-tool-calling-orkestrasyon.md) · [Index](index.md)

## Amaç

`AGENTS.md` protokolünde tanımlanan **Uzay-Zamansal Bileşebilirlik (Spatiotemporal Composability)** mimarisini Rubik çekirdeğine kazandırmak:
1. **Zamansal Bileşebilirlik (Revertible Effects):** Çevreye yapılan her yan etkinin (araç kaydı, hook, event dinleyicisi, geçici dosya) tersiyle ($\Omega$ LIFO akümülatörü) eşleştirilmesi ve bileşen kalktığında tam geri alınması.
2. **Uzamsal Bileşebilirlik (Reactive Coeffects):** Eklenti ve araçların bağımlılıklarını (coeffect) açıkça beyan etmesi ve bağımlılıklar sağlandığında reaktif olarak `Pending` → `Active` durumuna geçmesi.
3. **Alt Bağlam İzolasyonu (`ctx.extend()`):** Ajanın kendi ürettiği deneysel araçları veya alt görevleri izole sub-context'lerde koşturması; hata durumunda atomik geri alma yapması.

## Görevler (kolaydan zora)

1. `Rubik::Runtime::Context`:
   - `register_disposable(cleanup_fn)`: Yan etkilerin tersini LIFO sırada takip eden akümülatör ($\Omega$).
   - `provide(service_name, service)` / `require(service_name)`: Reaktif coeffect bağımlılık çözümleme.
   - `extend()`: Disposable alt bağlam üretimi.
   - `dispose()`: Tüm birikmiş ters dönüşümleri (inverses) LIFO sırayla çalıştırma.
2. `Rubik::Runtime::Fiber` Durum Makinesi:
   - Durumlar: `Pending` ⟷ `Active` ⟶ `Failed` ⟶ `Disposed`.
   - Coeffect'ler sağlandığında fabrikayı çalıştırıp `Active` yapma; bağımlılık koptuğunda $\Omega$ çalıştırıp `Pending`'e alma.
3. Dinamik ve Sıfır Kesintili Araç Değişimi (Zero-Downtime Tool Swapping):
   - Ajan çalışma anında yeni bir araç sentezlediğinde veya güncellediğinde, eski sürümü güvenle `dispose` edip yenisini aktifleştirme.
4. `Rubik::Plugin::Manager` Dönüşümü:
   - Statik `require` yerine, eklentilerin bir `Context` nesnesi alarak servis ve araçlarını register etmesi.
5. Oturum İzolasyonu:
   - REPL oturumunda çalıştırılan her bağımsız prompt döngüsünün `ctx.extend()` içinde izole edilmesi; oturum iptalinde (`Ctrl+C` / hata) çevreye sızan dinleyicilerin ve kaynakların anında temizlenmesi.

## Kabul Kriterleri

- [ ] Bir eklenti veya araç kaldırıldığında/yenilendiğinde bellekte hiçbir öksüz dinleyici, açık dosya veya zombi thread kalmaz (1000 kez arka arkaya yükle-kaldır sızıntısız geçer).
- [ ] Aktivasyon sırasında hata fırlatan bir eklenti, o ana kadar yaptığı tüm kısmi kayıtları atomik olarak geri alır (Atomic Context Rollback).
- [ ] Ajanın deneysel araç sentezi izole `ctx.extend()` içinde başarıyla doğrulanıp kalıcı runtime'a terfi ettirilir.

## Bağımlılıklar

- [Plan 14 (Eklenti Sistemi)](14-eklenti-sistemi.md)
- [Plan 10 (Tool-Calling Orkestrasyonu)](10-tool-calling-orkestrasyon.md)
- [Plan 01 (İskelet ve Olay Veri Yolu)](01-proje-iskeleti-ve-konfigurasyon.md)
- `AGENTS.md` (Spatiotemporal Composability Protocol)

## Test Stratejisi

- Birim: `Context` LIFO disposable stack, `Fiber` durum makinesi geçişleri, eksik coeffect reaktivitesi.
- Stres: 1000 iterasyonluk dinamik araç kayıt/unreg döngüsü; bellek sızıntısı ve öksüz listener denetimi.
