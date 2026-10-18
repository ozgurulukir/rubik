# Dil Sunucularını Kurma

> Bu belge, [Language-server guide](language-servers.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

## LSP entegrasyonu size ne kazandırır?

Rubik, stdio üzerinden (RFC 8089'e göre `file://` URI'leriyle JSON-RPC) herhangi
bir standart Language Server Protocol (LSP) sunucusuna bağlanır ve onu agent
döngüsü içinde canlı bir derleyiciye dönüştürür. Yalnızca Rubik'in saf-AST
analizine güvenmek yerine agent, derleyici seviyesinde tip ve semantik geri
bildirim alır: her düzenlemeden sonra gerçek zamanlı tanılama (diagnostics),
hover ile tip/dokümantasyon bilgisi ve go-to-definition sorguları. Entegrasyon
çok dillidir — her dil için bir sunucu ikili dosyası (binary) — ve
`Rubik::LSP::Manager` (`lib/rubik/lsp/manager.rb`) tarafından yönetilir; bu
bileşen sunucuları çalışma zamanı bağlamı üzerinde revertible effect olarak
başlatır, denetler ve durdurur.

## 1. Gereksinimler

- İlgilendiğiniz her dil için bir dil sunucusu ikili dosyası; kurulu olmalı ve
  `PATH` üzerinde bulunmalı. Rubik asla sizin için sunucu kurmaz; ikili dosya
  eksikse ilgili dil sessizce saf-AST analizine geri döner.
- Başka bir bağımlılık yoktur: sunucular, proje dizininizde köklenen alt
  süreçler (child process) olarak başlatılır ve bağlam (context) dispose
  edildiğinde temizce durdurulur.

## 2. Hızlı kurulum

LSP varsayılan olarak etkindir. Özelleştirmek için proje yapılandırmanıza (repo
kökünde `.rubik/config.yml` veya `rubik.yml`) ya da global yapılandırmanıza
(`~/.rubik/config.yml`) bir `lsp:` bloğu ekleyin:

```yaml
lsp:
  enabled: true            # master switch for the LSP engine
  auto_start: true         # start a server in the background when its file type is touched
  auto_diagnostics: true   # feed compiler/linter errors back to the model right after write_file
  servers:                 # language -> launch command (override any entry)
    ruby: "typeprof --lsp --stdio"
    python: "ruff server"
    go: "gopls"
```

Yapılandırma anahtarları (varsayılanlar `lib/rubik/config/defaults.rb`
içindendir):

| Anahtar                | Varsayılan | Açıklama                                                        |
| ---------------------- | ---------- | --------------------------------------------------------------- |
| `lsp.enabled`          | `true`     | LSP motorunu etkinleştirir (`false` = yalnızca saf AST).        |
| `lsp.auto_start`       | `true`     | Eşleşen bir dosya açıldığında dil sunucusunu otomatik başlatır. |
| `lsp.auto_diagnostics` | `true`     | Düzenlemelerden sonra severity-1 hataları modele geri iletir.   |
| `lsp.servers.<lang>`   | aşağıda    | Dil başına başlatma komutu.                                     |

Varsayılan sunucu komutları (`lsp.servers`):

| Dil                        | Varsayılan komut                     |
| -------------------------- | ------------------------------------ |
| `go`                       | `gopls`                              |
| `rust`                     | `rust-analyzer`                      |
| `zig`                      | `zls`                                |
| `c`, `cpp`                 | `clangd`                             |
| `python`                   | `ruff server`                        |
| `ruby`                     | `typeprof --lsp --stdio`             |
| `typescript`, `javascript` | `typescript-language-server --stdio` |
| `bash`                     | `bash-language-server start`         |
| `crystal`                  | `crystalline`                        |
| `gleam`                    | `gleam lsp`                          |
| `vue`                      | `vue-language-server --stdio`        |

Not: `lsp.servers.<lang>` anahtarı yoksa `Rubik::LSP::Client::SERVERS` içindeki
sabit kodlanmış (hard-coded) yedek kullanılır (yalnızca `python` için
farklıdır: `pylsp`); üçüncü yedek ise bilinen alternatifleri yoklar
(`Runtime::Discovery::LSP_CANDIDATES`), örn. Ruby: `solargraph stdio`,
`ruby-lsp`, `typeprof`; Python: `pyright-langserver --stdio`, `pylsp`,
`jedi-language-server`.

## 3. Dil sunucusu kurulumu (dile özel ipuçları)

Kurulum komutları genel örneklerdir — platformunuzun paket yöneticisini
kullanın (scoop, brew, apt, cargo, gem, npm, pip). Sunucu ikili dosyasının
`PATH` üzerinde bulunması gerekir.

- **go**: `go install golang.org/x/tools/gopls@latest`
- **rust**: `rustup component add rust-analyzer`
- **zig**: `zls`'i paket yöneticinizden kurun veya kaynaktan derleyin
- **c / cpp**: `clangd`, LLVM/clang ile birlikte gelir (örn. `scoop install llvm`)
- **python**: `pip install ruff` (alternatifler: `npm install -g pyright`, `pip install python-lsp-server`)
- **ruby**: `gem install typeprof` (alternatifler: `gem install solargraph` veya `gem install ruby-lsp`)
- **typescript / javascript**: `npm install -g typescript-language-server typescript`
- **bash**: `npm install -g bash-language-server`
- **crystal**: `crystalline` — bir sürüm ikili dosyasını indirin veya paket yöneticinizi kullanın
- **gleam**: Gleam araç zinciriyle birlikte gelir (sunucu `gleam lsp`'dir)
- **vue**: `npm install -g @vue/language-server`

## 4. Çalışma zamanında nasıl çalışır

**Tembel, talep üzerine başlatma.** Uzantısı desteklenen bir dile karşılık
gelen bir dosyaya dokunulduğunda (`.rb`, `.py`, `.ts`, `.go`, `.rs`, `.zig`,
`.c`, `.cr`, `.gleam`, `.vue`, `.sh`, ...), `Manager#client_for`
yapılandırılmış komutu çözer, ikili dosya eksikse yedekleri dener ve
(`lsp.auto_start: true` ile) sunucuyu başlatıp proje kökünüzle `initialize`
el sıkışmasını gerçekleştirir. Çalışan her istemci, kayıtlı bir dispose
inverse'i ile bağlam üzerinde `lsp:<lang>` olarak sağlanır; böylece bağlam
dispose edildiğinde sunucular temizce (LIFO) durur. Çökme devre kesicisi
(circuit breaker), 3 ardışık çökmeden sonra 5 dakika boyunca yeniden başlatma
girişimlerini durdurur.

**Bellek içi tamponla JIT tampon senkronizasyonu.** Rubik, dosyaları diske
uygulanmadan önce sanal tamponunda düzenler. Herhangi bir LSP sorgusundan
önce yönetici `sync_buffer_file_if_needed` çağırır; bu, yalnızca *kirli*
(dirty) tampon içeriklerini sunucuya `textDocument/didOpen` / `didChange`
üzerinden iter — böylece tanılamalar kaydedilmemiş düzenlemelerinizi
yansıtır ve bayat tanılamalar her değişiklikte geçersiz kılınır. Bir tamponun
uygulanmamış değişiklikleri varsa ve sunucu hiçbir şey bildirmiyorsa,
araçlar `apply_buffer` çalıştırma ipucu ekler (bazı sunucular diskten
indeksler).

**Düzenlemelerden sonra gerçek zamanlı geri bildirim.** Başarılı bir
`write_file` veya `replace_file_content` işleminin ardından adım yürütücüsü
(step executor) dosyayı sunucuya senkronize eder ve `lsp.auto_diagnostics`
açıksa kısa bir süre `textDocument/publishDiagnostics` bekleyip severity-1
(ERROR) öğelerini araç sonucuna ekler; modele devam etmeden önce bunları
düzeltmesini söyler. Dilerseniz açıkça da sorgulayabilirsiniz:

- `lsp_diagnostics` (`diagnostics`, `lint_errors` takma adları) — tek bir
  dosya (`file_path`) veya tüm çalışma alanı için hatalar/uyarılar; önce
  tamponu senkronize eder.
- `lsp_hover` (`hover_info`, `type_info`) — 1 tabanlı `file_path` + `line` +
  `character` konumunda tip imzası/dokümantasyonu.
- `lsp_definition` (`goto_definition`) — bir sembolün tanım konum(lar)ı.

**REPL komutları.** Entegrasyonu kabuktan inceleyin ve denetleyin:

- `!lsp status` (veya `!lsp servers`) — motor durumu, sunucu başına durum
  (RUNNING / AVAILABLE / NOT FOUND) ve tanılama sayıları.
- `!lsp on` / `!lsp off` (`--project` veya `--global`) — `lsp.enabled`
  değerini kalıcı kaydeder; `off` ayrıca çalışan tüm sunucuları durdurur.
- `!lsp diag [file]` (takma ad: `!diagnostics [file]`) — canlı tanılamaları
  yazdırır.
- `!lsp start <lang>` / `stop [lang]` / `restart [lang]` — manuel yaşam
  döngüsü denetimi; başarısız bir `start`, çözüm önerisini ve denenen
  adayları yazdırır.

## 5. Sorun Giderme

- **"Server binary '...' not found in PATH"** — başlatma komutunun ilk
  kelimesi `PATH` üzerinde çalıştırılabilir bir dosya olmalıdır. Sunucuyu
  kurun (bölüm 3) veya `lsp.servers.<lang>` değerini mutlak bir yola
  yönlendirin, ardından `!lsp restart <lang>` çalıştırın.
- **Bir dil için yanlış veya eksik sunucu** — neyin seçildiğini
  `!lsp status` ile kontrol edin; hata çıktısı denenen yedek adayları
  listeler. Açık bir `lsp.servers.<lang>` girdisiyle ezin (override).
- **Yavaş başlatma veya gürültücü sunucular** — `lsp.auto_start: false`
  ayarlayın ve sunucuları `!lsp start <lang>` ile talep üzerine başlatın;
  çöken bir sunucu devre kesicisi aracılığıyla 5 dakika boyunca kendini
  otomatik devre dışı bırakır.
- **Dil başına devre dışı bırakma** — `lsp.servers.<lang>` değerini var
  olmayan bir komuta yönlendirin; ilgili dil saf-AST analizinde kalır.
- **Tanılamalar düzenlemelerimi yansıtmıyor** — tampon muhtemelen hiç
  senkronize edilmedi çünkü diskte temiz; `apply_buffer` çalıştırın ve
  yeniden sorgulayın.

## 6. Doğrulama

Davranışsal referans testleri (deponun test takımıyla birlikte çalıştırın):

- `test/unit/test_lsp_manager_and_diagnostics.rb` — yapılandırma
  varsayılanları ve açma/kapama, uzantı-dil saptaması, tanılama işleme,
  araç çıktısı, REPL komutları, orkestratörün canlı tanılama geri bildirim
  döngüsü ve `did_change` üzerinde bayat tanılama geçersiz kılınması.
- `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb` — just-in-time
  tampon senkronizasyonu semantiği (yalnızca kirli tamponlar itilir);
  `test_lsp_client.rb`, `test_lsp_circuit_breaker.rb` ve
  `test_lsp_robustness.rb` protokolü ve hata yollarını kapsar.

---

[English source](language-servers.md) · [Belge dizini](../index.md) · [Türkçe README](../../README.tr.md).
