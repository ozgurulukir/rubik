# 📋 Plan 48: Harici Erişim İzinli Dizinler (External Allowed Dirs) ve Sıfır-AST Sandbox Güvenlik Kapısı

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** Kolay–Orta · **Faz:** 5 (Güvenlik & Çoklu Kök Dizin Mimarisi)  
> **İlgili Planlar:** [03](03-bellek-ici-tampon-buffer-yonetimi.md), [12](12-guvenlik-denetimi-ve-onay-mekanizmasi.md), [13](13-izole-calistirma-process-sandbox.md), [19](19-gelismis-sandbox-ve-docker-wasm.md), [40](40-coklu-calisma-alani-ve-ek-kok-dizin-erisim-yonetimi.md), [46](46-ast-ve-baglam-motorunun-reaktif-coeffect-servisine-donusturulmesi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

### Mevcut Durum:
1. `workspace.additional_roots` (Plan 40) mekanizması eklenen tüm kök dizinleri **tam bir çalışma alanı (full workspace root)** olarak ele alır:
   - Dosyaları `Context::Scanner` ile taranır ve prompt XML dosya ağacına eklenir.
   - Tüm kaynak kodlar `AST::Graph` içine indekslenir ve semboller belleğe alınır.
2. Ancak ajanın bazen `/tmp/my_scratch`, `/tmp/artifacts`, `/var/data` veya geçici derleme alanları gibi **kod tabanına ait olmayan harici dizinlerde okuma/yazma ve komut çalıştırması** gerekir.
3. Bu dizinler `workspace root` olarak eklenirse:
   - Yüzlerce geçici dosya sistem prompt'una dökülür (token israfı ve modelin kafasının karışması).
   - AST grafiği alakasız geçici sembollerle şişer.
4. Bu dizinler hiç eklenmezse:
   - Sandbox ve `Buffer::Manager` güvenlik kalkanı (`InvalidPathError: Path traversal attempt blocked`) bu dizinlere erişimi tamamen engeller.

### Çözüm Vizyonu:
`workspace.additional_roots` (Tam Çalışma Alanı) ile `workspace.allowed_external_dirs` (Salt İ/O ve Sandbox İzinli Dizinler) ayrımını netleştirmek ve birleşik bir **Mantıksal VEYA (OR) Güvenlik Kapısı** inşa etmek:

$$\text{Erişim İzni} \iff \text{Hedef} \in \text{Project Root} \lor \text{Hedef} \in \text{Additional Roots} \lor \text{Hedef} \in \text{Allowed External Dirs}$$

Bu sayede:
- **Tam Güvenlik:** Ajan yalnızca izin verilen listelenmiş dizinlerde çalışır (izinsiz yollara erişemez).
- **Sıfır AST & Sıfır Token İsrafı:** Harici dizinler AST sembollerine veya prompt dosya ağacına **asla sokulmaz**.

---

## 🏛️ 2. Mimari Tasarım ve Güvenlik Matrisi

```
                              ┌──────────────────────────────────────────────┐
                              │            Target Path Resolution            │
                              └──────────────────────┬───────────────────────┘
                                                     │
                   ┌─────────────────────────────────┼─────────────────────────────────┐
                   ▼                                 ▼                                 ▼
    ┌─────────────────────────────┐   ┌─────────────────────────────┐   ┌─────────────────────────────┐
    │     1. Primary Root Dir     │   │ 2. Workspace Additional     │   │  3. Allowed External Dirs   │
    │         (@root_dir)         │   │       (@additional_roots)   │   │  (@allowed_external_dirs)   │
    ├─────────────────────────────┤   ├─────────────────────────────┤   ├─────────────────────────────┤
    │ • Buffer I/O: Read / Write  │   │ • Buffer I/O: Read / Write  │   │ • Buffer I/O: Read / Write  │
    │ • Sandbox: Allowed          │   │ • Sandbox: Allowed          │   │ • Sandbox: Allowed          │
    │ • Context Scanner: YES      │   │ • Context Scanner: YES      │   │ • Context Scanner: ❌ ZERO  │
    │ • AST Symbol Graph: YES     │   │ • AST Symbol Graph: YES     │   │ • AST Symbol Graph: ❌ ZERO │
    │ • Prompt Tree XML: YES      │   │ • Prompt Tree XML: YES      │   │ • Prompt Tree XML: ❌ ZERO  │
    └─────────────────────────────┘   └─────────────────────────────┘   └─────────────────────────────┘
                   │                                 │                                 │
                   └─────────────────────────────────┼─────────────────────────────────┘
                                                     ▼
                                      [ Mantıksal VEYA (OR) Kapısı ]
                                                     │
                                     ┌───────────────┴───────────────┐
                                     ▼                               ▼
                             [ ✅ İzin Verildi ]             [ 🔴 BLOCKED ]
                             (Güvenli Erişim)           (InvalidPathError)
```

---

## ⚙️ 3. Planlanan İyileştirmeler ve Kodlama Adımları

### 3.1. `Rubik::Config` Yapılandırma Şeması
[`lib/rubik/config.rb`](file:///home/aristo/Projects/rubik/lib/rubik/config.rb) içinde `DEFAULT_CONFIG["workspace"]` genişletilir:
```ruby
"workspace" => {
  "additional_roots" => [],          # AST + Scanner + Buffer (Full Workspace)
  "allowed_external_dirs" => [],     # Buffer + Sandbox ONLY (Zero-AST, Zero-Scanner)
  "allow_external_writes" => false,
  "auto_index_additional" => true
}
```

### 3.2. `Rubik::Buffer::Manager` Mantıksal OR Güvenlik Kapısı
[`lib/rubik/buffer/manager.rb`](file:///home/aristo/Projects/rubik/lib/rubik/buffer/manager.rb):
- `@allowed_external_dirs = Set.new(Array(allowed_external_dirs).map { |d| File.expand_path(d) })`
- `add_allowed_dir(path, rw: true)`, `remove_allowed_dir(path)` metotları.
- `sanitize_path(path, for_write: false)`:
  - Yol `@root_dir`, `@additional_roots` veya `@allowed_external_dirs` altındaysa güvenli kabul edilir.
  - Değilse `InvalidPathError: Path traversal attempt blocked` fırlatır.

### 3.3. `Rubik::Security::Guard` ve `Rubik::Sandbox::Runner` Entegrasyonu
- `Sandbox::Runner`: Komut çalıştırmadan önce `cwd` veya hedef dosyanın izin verilen kökler / harici dizinler içinde olduğunu doğrular.
- Tehlikeli sistem kökleri (`/`, `/etc`, `/usr`, `/home`) eklenmeye çalışılırsa `verify_root_safety!` ile engellenir.

### 3.4. Sıfır AST ve Sıfır Scanner Garantisi
- `Rubik::Context::Scanner` ve `Rubik::AST::Graph`:
  - Yalnızca `@root_dir` ve `@additional_roots` dizinlerini tarar.
  - `@allowed_external_dirs` asla taranmaz; böylece `/tmp/my_scratch` içindeki dosyalar prompt bağlamını ve AST belleğini kirletmez.

### 3.5. REPL Komutları: `!allow` / `!workspace allow`
[`lib/rubik/repl/commands/workspace.rb`](file:///home/aristo/Projects/rubik/lib/rubik/repl/commands/workspace.rb):
- `!allow <path> [--rw] [--project|--global]` (veya `!workspace allow <path>`)
- `!allow list`
- `!allow remove <path>`
- `!config set workspace.allowed_external_dirs ["/tmp/scratch"]`

---

## 🧪 4. Test ve Kalite Güvencesi

1. **`test/unit/test_allowed_external_dirs.rb`**:
   - `allowed_external_dirs` eklenmiş bir yola (`/tmp/rubik_test_dir`) tampon üzerinden yazma ve okuma yapılması.
   - `Scanner` ve `AST::Graph`'ın bu dizini **taramadığının** (Sıfır AST ve Sıfır Dosya Ağacı kirliliği) teyidi.
   - İzin verilmeyen bir dış yola yazma denendiğinde `InvalidPathError` ile engellenmesi.
   - REPL `!allow` ve `!config set workspace.allowed_external_dirs` komutlarının testi.
   - `Sandbox::Runner` içinde `chdir` güvenlik doğrulaması ve dinamik ekleme/çıkarma testleri.
2. **Mevcut Test Süiti:** Tüm testler %100 uyumlu ve yeşil.

---

## 📊 5. Uygulama Sonuç Raporu

- ✅ **`lib/rubik/config.rb`:** `DEFAULT_CONFIG["workspace"]["allowed_external_dirs"] = []` şeması tanımlandı.
- ✅ **`lib/rubik/buffer/manager.rb`:** `@allowed_external_dirs`, `@rw_allowed_dirs`, `add_allowed_dir(path, rw: true)`, `remove_allowed_dir(path)` metotları ve mantıksal OR güvenlik kapısı (`@root_dir || @additional_roots || @allowed_external_dirs`) eklendi.
- ✅ **`lib/rubik/sandbox/runner.rb`:** `allowed_paths`, `verify_chdir_safety!(chdir)`, `add_allowed_dir`, `remove_allowed_dir` metotları uygulandı; `run(cmd, chdir: ...)` içinde `chdir` güvenlik denetimi entegre edildi.
- ✅ **`lib/rubik/repl/shell.rb`:** `allowed_external_dirs` yapılandırması `Buffer::Manager` ve `Sandbox::Runner` bileşenlerine aktarıldı; `allow` ve `allow-dir` tracked komut listesine alındı.
- ✅ **`lib/rubik/repl/commands/workspace.rb`:** `!allow`, `!allow-dir`, `!workspace list` (hem çalışma alanı köklerini hem izinli harici dizinleri gösterme), `!workspace allow` ve `!config set workspace.allowed_external_dirs` senkronizasyonu bağlandı (AST/Scanner tetiklenmez).
- ✅ **`test/unit/test_allowed_external_dirs.rb`:** Kapsamlı birim ve entegrasyon testleri başarıyla yazıldı.
