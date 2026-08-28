# 55 — run_command için Platform-Kapılı Kabuk Seçimi ve Ortam Yayını

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟡 **Planlandı — uygulama bekliyor** · **Zorluk:** Orta · **Faz:** 6 (Bakım & Kod Sağlığı)  
> **İlgili Planlar:** [13](13-izole-calistirma-process-sandbox.md), [49](49-tam-kapsamli-cross-platform-ve-windows-uyumluluk-mimarisi.md), [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md)  
> **Kapsam:** `lib/rubik/sandbox/driver/process.rb`, yeni `lib/rubik/sandbox/shell_resolver.rb`, `lib/rubik/tools/builtins/exec.rb` (yalnız `RunCommandTool`), `lib/rubik/prompt/context_builder.rb` (tek satır), `CONFIG.md`/`README.md`  
> **Ön Çalışma:** 28 Ağustos 2026 oturum teşhisi — gerçek ajan transkriptindeki `run_command` hatalarının yeniden üretimi ve dört kabuğun ölçümü (§2)

---

## 🎯 1. Hedef ve Gerekçe

Gerçek bir ajan oturumunda `run_command` hatalarının üç sınıfı tespit edildi ve yeniden üretildi: `grep`'in "eşleşme yok" çıkışının hata sanılması, `<(...)` süreç ikamesinin kırılması, uydurulmuş git ref'i. Kök neden tek: **ProcessDriver komutları Ruby'nin örtük yorumlayıcısına bırakıyor** — Windows'ta bu sessizce cmd.exe demek. Model ise bash yazıyor (LLM eğitim veriminin varsayılanı POSIX), çünkü sisteme hangi kabuğun çalıştığı **hiçbir yerde** söylenmiyor: araç açıklamasında yok, sistem isteminde yok (prompt/ altında platform bilgisi sıfır), sonuç çıktısında yok.

Bu plan üç küçük ayakla sorunu kapatıyor — kapı çözümleme (nerede koşacak), etiket (neyin koştuğu), yayın (önceden bilme). Bilinçli olarak minimal tutulur: tek yeni modül, tek yeni config anahtarı, sözleşme yüzeyi büyütülmez.

---

## 🔍 2. Teşhis ve Ölçümler (28 Ağustos 2026, bu makine)

### 2.1 Bugünkü Davranış

`ProcessDriver#run` → `Open3.popen3(env, cmd, chdir:)` — string komut Windows'ta örtük olarak **cmd.exe**'ye gider (kanıt: `%OS%` → `Windows_NT` açılıyor, `$0` literal basılıyor). Bash'e hiç gidilmiyor; oysa `bash -c "..."` açıkça yazılırsa hat boyunca kusursuz çalışıyor.

### 2.2 Kabuk Ölçüm Tablosu

| Kabuk | Native exit kodu | `&&` | `$(...)` | `/dev/null` | Başlatma |
| :--- | :---: | :---: | :---: | :---: | :---: |
| cmd | ✅ | ✅ | ❌ sessizce literal | ❌ path hatası | **53 ms** |
| bash (Git Bash) | ✅ | ✅ | ✅ | ✅ | **47 ms** |
| pwsh 7 | ✅ (grep→1, `exit 7`→7) | ✅ | ✅ | ❌ Out-File hatası | **394–1326 ms** |
| powershell 5.1 | kısmen | ❌ parse hatası | — | ❌ | ~900 ms |

### 2.3 Model Bilgisizliğin Kanıtı

Transkriptteki model `<(...)` ve `&&` birlikte yazdı: POSIX zihniyeti. Kabuk kimliği yayınlanmadığı için bu bir tahmin ve tahmin cmd'de kırılıyor; hata metni de nedenini açıklamıyor.

---

## 🏛️ 3. AGENTS.md Hizalaması

- **Örtük yorumlayıcı = örtük bağımlılık:** §5'in "Implicit Global Singletons" ruhunu işlem düzeyinde yansıtır — çalışma ortamı tahmin edilemez olamaz. Açık argv ile yürütme deterministiktir.
- **Context-Mediated Operations:** Kabuk kimliği artık sistemin paylaşılan bağlamında (`<environment>` satırı) yayımlanır; ajan belirsiz varsayım yerine açık bilgiyle çalışır.
- Kapsam bilinçli olarak küçüktür; protokolün yeni bir yüzeyi **açılmaz** (yeni servis, fiber, coeffect eklenmez).

---

## 🧩 4. Tasarım Kararları

**D-1 — Açık argv, örtük yorumlayıcı yok.** ProcessDriver çözülen kabuğu dizi biçiminde çalıştırır: `["bash","-c",cmd]`, `["pwsh","-NoProfile","-NonInteractive","-Command",cmd]`, `["cmd","/c",cmd]`, `["sh","-c",cmd]`. Dizi biçimi Ruby'nin string'i cmd'ye sarmasını da imkânsız kılar (bugün `bash -c` bile dolaylı cmd geçişine açık).

**D-2 — Auto çözümleme sözdizimi-kapılıdır; şüphede bash'e kayar.** Sıra:
1. **bash-zorunlu sözdizimi** — `<(`, `>(`, `<<`, `/dev/null` (cmd **ve** pwsh'te kırılıyor) → bash.
2. **PowerShell parmak izi** — `$env:`, `Get-\w+` → pwsh.
3. **`$`-referans/ikame** — `$(`, backtick, `$\w` (cmd'de sessizce yanlış) → bash.
4. **Düz komut** (`&&`, `||`, `|`, düz binary) → platform default'u: Windows'ta **cmd** (ölçülmüş 53 ms hızlı yol; pwsh ~10–25× başlatma vergisi — D-3'teki tek satırla tersine çevrilebilir), Unix'te bash (yoksa sh).

Yanlış-pozitif (düz komutun bash'e gitmesi) zararsızdır — bash düz komutların üst kümesini doğru çalıştırır; yanlış-negatif kırıcıdır. Eşikler bu yöne ayarlıdır.

**D-3 — Kapalı ve minik kabuk seti.** `sandbox.shell: auto | bash | pwsh | cmd | sh` (varsayılan `auto`). Geçersiz değer → `auto` (fail-open değil, sessiz düzeltme). **powershell 5.1 bilinçli olarak set dışıdır** (`&&` yok + exit kodu güvenilmez — ölçüldü); gerekirse `powershell -Command ...` komutun kendisi olarak yazılabilir.

**D-4 — Çağrı-başı shell parametresi YOK.** Kaçış kapısı zaten var: `bash -c "..."` bugün bile çalışıyor ve D-6'daki ortam satırında duyuruluyor. Araç şemasına yeni alan eklemek sözleşme yüzeyini ve guard/etiket mantığını büyütür; auto-kapı + kaçış kapısı kombinasyonu yeterli.

**D-5 — Sonuca kabuk etiketi.** `[EXIT 1] (bash)` / `[OK] (cmd)` — etiket, varolan önekin **ardına** eklenir; `is_err` sezgiselinin `"[EXIT "` önek kontrolü dokunulmaz. Kabuk bilgisi driver sonuç hash'ine `shell:` anahtarıyla girer; `RunCommandTool` yalnızca varsa basar (docker/podman/wasm sürücüleri kendi kabuğunu yazar ya da atlar). Model, hatasından hangi kabukta olduğunu öğrenerek çıkar.

**D-6 — Ortam yayını: tek satır, tek doğruluk kaynağı.** Sistem istemine: `<environment os="windows" shell="cmd (plain) / bash (POSIX: <(...), $(...), /dev/null) via auto-routing; escape hatch: bash -c '...'" />` ≈ 30 token. Metin `ShellResolver`'dan gelir (prompt↔sandbox arasında tek kaynak; require yönü prompt→sandbox, döngüsüz). Model ilk komutu yazmadan önce bilir.

**D-7 — Kabuk yoksa açıklama, ret değil.** bash-zorunlu sözdizimi + bash kurulu değil → komut yine default kabukta denenir, çıktının başına tek satır not eklenir ("POSIX syntax detected; bash not found — this will likely fail under cmd"). Reddetmek ajanı bloklar; not etmek eğitir.

**D-8 — Bilinçli kapsam dışı (borç yaratmamak için).**
- `[EXIT 1]` + boş çıktı için grep-ipucu — kozmetik; D-5 etiketi deneyimi zaten iyileştiriyor, grep'e özel sezgi borçtur.
- powershell 5.1, WSL, `shell` per-call argümanı, driver bazlı kabuk konfigürasyonu.
- Docker/Podman/WASM sürücüleri değişmez (kapsayıcı içindeki kabuk zaten sh ailesi).
- `!sh` REPL komutu aynı hattı kullandığı için otomatik yararlanır; ayrı kod girmez.

---

## 📦 5. Uygulama Fazları

### Faz A — ShellResolver + Açık argv (çekirdek)
1. `lib/rubik/sandbox/shell_resolver.rb` (yeni, ~90 satır): `module_function` — `resolve(cmd, platform:)` → `{ argv:, shell:, note: }`; `default_shell(platform)`; `environment_line`; kabuk varlık kontrolü `Platform.which` üzerinden. Sınıf hiyerarşisi yok, yalnız saf fonksiyonlar.
2. `ProcessDriver#run`: cmd string'ini resolver'dan geçiren argv ile çalıştırır; sonuç hash'ine `shell:` ekler. Zaman aşımı/kill_tree/env-proxy akışı değişmez.
3. Birim testler: parmak-izi matrisi (platform stub'lı), kapalı-set doğrulaması, not üretimi.

### Faz B — Etiket + Yayın + Config
1. `RunCommandTool`: çıktıya `(shell)` etiketi (yalnız `shell:` varsa).
2. `context_builder`: `build_system_context` içine tek `<environment>` satırı (D-6).
3. `Config` üzerinden `sandbox.shell` okuma (mevcut fetch mekanizması; yeni yapı yok).

### Faz C — Belge ve Doğrulama
1. `CONFIG.md`: kabuk matrisi + ölçüm tablosu + `sandbox.shell`. `README.md`: "Ajan Kabuk Davranışı" kısa paragrafı.
2. Uçtan uca senaryo testleri (gerçek transkriptteli üç komut): `<(...)` → bash'te başarılı; `$(pwd)` → değer; düz `git ... && ...` → cmd'de 100 ms altı; PS komutu → pwsh'te.
3. Exit kodu yayılımı: bash/pwsh'te native kod korunur (ölçümdeki grep→1, exit 7→7 senaryoları).

---

## 🧪 6. Test Stratejisi

| Test | Tür | Kapsam |
| :--- | :--- | :--- |
| `test_shell_resolver.rb` (yeni) | Birim | Parmak izi matrisi × platform; geçersiz config → auto; bash yok → not; kapalı set |
| `test_sandbox_*` (mevcut, genişletme) | Entegrasyon | Gerçek bash/pwsh/cmd yolları (ikili yoksa `skip`); exit kodu yayılımı; etiket; zaman aşımı korunur |
| `test_expanded_tools.rb` (genişletme) | Davranış | `RunCommandTool` çıktı biçimi `[EXIT 1] (bash)`; etiket yoksa eski biçim |
| `test_structured_context_builder.rb` (genişletme) | Birim | `<environment>` satırı var; `bash -c` kaçış kapısı geçiyor |
| Transkript senaryosu | Uçtan uca | Kullanıcının 3 örneğinin akıbeti: 2'si düzelir, git-ref örneği bilinçli olarak aynı kalır (model hatası) |

---

## ✅ 7. Kabul Kriterleri

- [ ] ProcessDriver'da örtük (string) spawn kalmaz; tüm yollar açık argv'den geçer.
- [ ] Transkript senaryosu: `<(...)` ve `$()`/`/dev/null` içeren komutlar bash'te **başarıyla** koşar; `2>/dev/null` sessizce çalışır.
- [ ] Düz komutlar Windows'ta cmd'de kalır (davranış/latensi paritesi); `&&` zincirleri kırılmaz.
- [ ] PS parmak izli komut pwsh'te koşar; native exit kodu bozulmaz.
- [ ] Sistem isteminde `<environment>` satırı görünür; kabuk seti/kapı davranışı tek kaynaktan türetilir.
- [ ] powershell 5.1 hiçbir auto yolunda kullanılmaz; geçersiz config auto'ya düşer.
- [ ] Tam paket yeşil kalır; rubocop: düzenlenen dosyalar HEAD ≤, yeni dosya 0 offense; yeni modül < 150 satır.

---

## ⚠️ 8. Riskler

| Risk | Azaltım |
| :--- | :--- |
| pwsh auto'ya girerse gecikme patlaması (10–25×) | pwsh yalnız PS-parmak izli komutlarda seçilir; düz yol cmd kalır (ölçüm §2.2) |
| MSYS bash yol-dönüştürme kenarları (`ls /tmp` argüman mangle) | Senaryo testlerinde örnekler; kaçış kapısı ve etiket teşhisi hızlandırır |
| Kapı yanlış-pozitifi davranış değişikliği | Yön güvenli (bash ⊃ cmd sözdizimi); mevcut sandbox test bataryası pariteyi korur |
| İki doğruluk kaynağı drift'i (resolver ↔ prompt metni) | Ortam satırı resolver'dan üretilir; elle metin yok |

---

## 📝 9. Sapmalar ve Uygulama Kayıtları

*Uygulama sırasında doldurulacaktır.*

| # | Konu | Plan'dan Sapma | Gerekçe |
| :--- | :--- | :--- | :--- |
| — | — | — | — |
