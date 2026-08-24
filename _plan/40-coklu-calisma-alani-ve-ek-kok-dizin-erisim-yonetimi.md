# 📋 Plan 40: Çoklu Çalışma Alanı ve Ek Kök Dizin Erişim Yönetimi (Multi-Workspace & Additional Roots Access)

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Orta · **Faz:** 5 (Güvenlik, Monorepo & Çalışma Alanı Yönetimi)  
> **İlgili Planlar:** [01](01-proje-iskeleti-ve-konfigurasyon.md), [03](03-bellek-ici-tampon-buffer-yonetimi.md), [12](12-guvenlik-denetimi-ve-onay-mekanizmasi.md), [25](25-yapilandirma-kaliciligi-ve-otomatik-kayit.md), [38](38-yaml-store-ile-guvenli-ve-transaksiyonel-kalicilik-refaktoru.md), [39](39-asenkron-ve-kademeli-ast-onbellegi-persistent-lazy-indexing.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum
1. **Tekil Kök Dizin Sınırı (`root_dir`):**
   - [`lib/rubik/buffer/manager.rb`](../lib/rubik/buffer/manager.rb) içindeki `sanitize_path` metodu, yalnızca tek bir `root_dir` dizinini kabul etmekte; bu dizinin dışına çıkan tüm yolları `Path traversal attempt blocked` hatasıyla engellemektedir.
2. **Monorepo ve Kardeş Paket İhtiyaçları:**
   - Çoklu servisli mimarilerde (Monorepo, microservices veya kardeş kütüphaneler), ana proje genellikle komşu dizinlerdeki ortak kodlara (`../shared-kernel`, `../proto`, `../contracts` vb.) veya harici dokümantasyon klasörlerine bağımlıdır.
3. **Kullanıcı Tanımlı Güvenli İzinler:**
   - Kullanıcı, belirli harici klasörlere okuma (`read-only`) veya hem okuma hem yazma (`read-write`) yetkisi vermek istediğinde bunu dinamik olarak yapılandırabilmeli (`!config` veya `!workspace` komutlarıyla) ve bu izinler `YAML::Store` ile kalıcı hale getirilmelidir.

---

## 🏛️ 2. Mimari Tasarım ve Güvenlik Modeli

```
                        ┌──────────────────────────────────────────────┐
                        │        Rubik Configuration & REPL            │
                        │   (!config workspace.additional_roots [...]) │
                        │   (!workspace add / list / remove)           │
                        └──────────────────────┬───────────────────────┘
                                               │
                       ┌───────────────────────┴───────────────────────┐
                       ▼                                               ▼
     ┌───────────────────────────────────┐           ┌───────────────────────────────────┐
     │      Primary Project Root         │           │    Allowed Additional Roots       │
     │      (e.g. ~/Projects/go-hayap)   │           │    (e.g. ~/Projects/shared-lib)   │
     ├───────────────────────────────────┤           ├───────────────────────────────────┤
     │ • Full read/write buffer access   │           │ • Explicit policy (ro vs rw)      │
     │ • AST & Context auto-indexing     │           │ • Security::Guard isolation       │
     │ • Monitored for git & dirty state │           │ • Dynamic mount & unmount in ctx  │
     └───────────────────────────────────┘           └───────────────────────────────────┘
                                               │
                                               ▼
     ┌───────────────────────────────────────────────────────────────────────────────────┐
     │                      Rubik::Buffer::Manager & Security::Guard                     │
     │   • sanitize_path(path): Check allowed roots whitelist                           │
     │   • Prevent access to unauthorized parent dirs, ~/.ssh, /etc, .env               │
     └───────────────────────────────────────────────────────────────────────────────────┘
```

---

## ⚙️ 3. Yapılandırma Şeması (`Config`)

[`lib/rubik/config.rb`](../lib/rubik/config.rb) içinde `DEFAULT_CONFIG` altına `workspace` bölümü eklenir:

```yaml
workspace:
  additional_roots: []       # İzin verilen ek mutlak veya göreceli dizinler: ["../shared-kernel", "/tmp/docs"]
  allow_external_writes: false # Ek kök dizinlere yazma izni verilsin mi? (Varsayılan: false -> Sadece Okuma)
  auto_index_additional: true  # Ek kök dizinler AST ve bağlam indeksine dahil edilsin mi?
```

### REPL Bang Komutları ve Ayarlanabilirlik:
1. **Genel Config ile Yönetim:**
   ```text
   rubik > !config workspace.additional_roots ["../shared-contracts", "../core-lib"]
   rubik > !config workspace.allow_external_writes true
   ```
2. **Özel `!workspace` / `!roots` Komutu:**
   ```text
   rubik > !workspace add ../shared-contracts
   [Rubik::Workspace] Added additional root: /home/aristo/Projects/shared-contracts (Mode: Read-Only)

   rubik > !workspace add ../core-lib --rw
   [Rubik::Workspace] Added additional root: /home/aristo/Projects/core-lib (Mode: Read-Write)

   rubik > !workspace list
   === Configured Workspace Roots ===
    • [PRIMARY] /home/aristo/Projects/go-hayap (Read-Write)
    • [EXTRA 1] /home/aristo/Projects/shared-contracts (Read-Only)
    • [EXTRA 2] /home/aristo/Projects/core-lib (Read-Write)

   rubik > !workspace remove ../shared-contracts
   [Rubik::Workspace] Removed additional root: /home/aristo/Projects/shared-contracts
   ```

---

## 🔒 4. Güvenlik ve Tampon İzolasyonu (`Buffer::Manager` & `Security::Guard`)

### A. Çoklu Kök Yol Doğrulaması (`Buffer::Manager#sanitize_path`)
```ruby
def sanitize_path(path, for_write: false)
  expanded = File.expand_path(path, @root_dir)
  allowed_roots = [@root_dir] + @additional_roots.map { |r| File.expand_path(r, @root_dir) }
  
  matched_root = allowed_roots.find { |r| expanded == r || expanded.start_with?("#{r}/") }
  unless matched_root
    raise InvalidPathError, "Path traversal attempt blocked: '#{path}'. Not within primary root or allowed workspace roots: #{allowed_roots.join(', ')}"
  end

  if for_write && matched_root != @root_dir && !@allow_external_writes
    raise InvalidPathError, "Write blocked on external workspace root: '#{path}'. Configure 'workspace.allow_external_writes: true' or add with --rw to enable writes."
  end

  expanded
end
```

### B. Kritik Sistem Dosyası Koruması
- Eklenen kök dizin `~` (Home) veya `/` (Root) gibi tehlikeli genişlikte bir dizin olamaz (`/`, `/home`, `/etc`, `/usr` ekleme girişimleri `Security::Guard` tarafından reddedilir).
- Ek kök dizin içindeki `.env*`, `.git/**`, `id_rsa*` gibi hassas dosyalar `Security::Guard#verify_path_write!` tarafından korunmaya devam eder.

---

## 🔍 5. AST & Bağlam İndeksi Entegrasyonu

1. **`Rubik::Context::Scanner`:**
   - Birincil kök haricinde `workspace.auto_index_additional: true` ise ek kök dizinlerdeki dosyalar da taranır.
2. **`Rubik::AST::Graph`:**
   - Ek dizinlerdeki fonksiyon ve sınıflar sembol tablosuna nitelikli anahtarlarıyla (`"go:../shared-contracts/models.go#User"`) eklenir.
   - `get_outline` ve `search_symbols` çoklu kök genelinde şeffaf çalışır.

---

## 🧪 6. Test ve Kalite Güvence Planı

1. **`test/unit/test_workspace_multi_roots.rb`:**
   - İzin verilen ek kök dizinlerden dosya okuma (`read_file`, `list_files`, `grep`).
   - `allow_external_writes: false` iken ek dizine yazmanın engellenmesi.
   - `allow_external_writes: true` iken bellek içi tampona yazıp diske uygulayabilme (`write_file`, `apply_buffer`).
   - İzin verilmeyen dizinlere erişim girişimlerinin `InvalidPathError` fırlatması.
   - Tehlikeli kök dizin engelleri (`/`, `/etc`, `/home`).
2. **`test/unit/test_workspace_command.rb`:**
   - `!workspace add`, `!workspace remove`, `!workspace list` ve `!config workspace.additional_roots` REPL komutlarının doğrulanması.
   - `YAML::Store` üzerinden yapılandırmanın kalıcı kaydedilmesi.
3. **Genel Test Regresyonu:**
   - Tüm 226 testin %100 yeşil kalması.

---

## 🚀 7. Uygulama Adımları

1. **Adım 1:** [`lib/rubik/config.rb`](../lib/rubik/config.rb) içine `workspace` varsayılanları ve şema doğrulaması ekle.
2. **Adım 2:** [`lib/rubik/buffer/manager.rb`](../lib/rubik/buffer/manager.rb) içinde `additional_roots` ve `allow_external_writes` desteğini uygula.
3. **Adım 3:** [`lib/rubik/security/guard.rb`](../lib/rubik/security/guard.rb) içine tehlikeli kök dizin blokajını ekle (`verify_root_safety!`).
4. **Adım 4:** [`lib/rubik/repl/shell.rb`](../lib/rubik/repl/shell.rb) içine `!workspace` komut grubunu tanımla (`add`, `remove`, `list`).
5. **Adım 5:** `test/unit/test_workspace_multi_roots.rb` test paketini oluştur ve tüm süiti (`rake test`) doğrula.
