# 🕹️ Rubik REPL Komut Kılavuzu (`COMMANDS.md`)

> Rubik etkileşimli REPL kabuğu içerisindeyken kod yazımı, otonom planlama, sağlayıcı yönetimi, bellek tamponu ve AST denetimi için kullanabileceğiniz tüm **Bang (`!`) Komutları**.

---

## 🏛️ Kalıcılık Kapsamı (Scoping) ve Geri Bildirim Kuralları

Rubik REPL içerisindeki ayar ve yönetim komutları 3 farklı kalıcılık kademesini destekler:

| Kapsam (Scope) | Bayrak (Flag) | Kalıcılık Durumu | Geri Bildirim Bildirimi |
| :--- | :--- | :--- | :--- |
| **Session Only** | *(Bayraksız)* veya `-s` / `--session` | Yalnızca o anki oturum boyunca bellekte aktiftir; diske yazılmaz. | `[Session only]` |
| **Project Level** | `-p` veya `--project` | Proje kökündeki `.rubik/config.yml` içine kalıcı kaydedilir. | `[Project level (.rubik/config.yml)]` |
| **System Level** | `-g` veya `--global` | Kullanıcı ev dizinindeki `~/.rubik/config.yml` içine kalıcı kaydedilir. | `[System level (~/.rubik/config.yml)]` |

---

## 📑 Hızlı Erişim İndeksi

1. [Model, Sağlayıcı & Yönlendirme](#-1-model-sağlayıcı--yönlendirme-komutları) (`!provider`, `!providers`, `!model`)
2. [Otonom Ajan, Planlama & Bütçe](#-2-otonom-ajan-planlama--bütçe-komutları) (`!plan`, `!goal`, `!steps`)
3. [Bellek İçi Tampon, Diff & Snapshot](#-3-bellek-içi-tampon-diff--snapshot-komutları) (`!diff`, `!apply`, `!autoapply`, `!undo`, `!rollback`)
4. [Spatiotemporal Runtime & Teşhis](#-4-spatiotemporal-runtime--canlı-teşhis-komutları) (`!runtime`, `!fibers`, `!agents`, `!services`)
5. [Kod Zekası, AST Grafı & LSP](#-5-kod-zekası-ast-grafı--lsp-komutları) (`!lsp`, `!symbols`, `!outline`, `!refs`, `!ast`, `!context`)
6. [Derleme, Test & Sandbox](#-6-derleme-test--güvenli-sandbox-komutları) (`!test`, `!lint`, `!format`, `!sh`)
7. [Oturum, Geçmiş & Ayarlar](#-7-oturum-geçmiş--genel-ayarlar) (`!session`, `!history`, `!replay`, `!config`, `!verbosity`, `!verbose`, `!status`, `!help`, `!quit`)
8. [Dinamik Sentezlenen Komutlar](#-8-dinamik-sentezlenen-komutlar-self-evolving)

---

## 🤖 1. Model, Sağlayıcı & Yönlendirme Komutları

### `!providers` & `!provider list`
Kayıtlı tüm LLM sağlayıcılarını, bağlantı uç noktalarını (endpoint), tiplerini ve tanımlı modelleri listeler.
```bash
!providers
!provider list
```

### `!provider add`
Yeni bir LLM sağlayıcısını ilk modeliyle birlikte canlı sisteme ekler.
```bash
# Doğrudan API anahtarı ile global ekleme:
!provider add deepseek openai_compatible https://api.deepseek.com/chat/completions --key=sk-your-key --model=deepseek-chat --context=64000 -g

# Ortam değişkeni ile global ekleme (Güvenlik / Git dostu):
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-3.7-sonnet --context=200000 -g

# Projeye özel eklemek için:
!provider add local_vllm openai_compatible http://localhost:8000/v1/chat/completions --model=qwen2.5-coder --context=32768 -p

# Yalnızca bu oturum için (Session Only):
!provider add test_provider openai_compatible http://localhost:11434 --model=llama3
```

### `!provider add-model` & `!provider set-context`
Mevcut bir sağlayıcıya yeni bir model tanımlar veya modelin context token limitini günceller.
```bash
!provider add-model deepseek deepseek-reasoner --context=64000 -g
!provider add-model openrouter deepseek/deepseek-r1 --context=128000 -g
!provider set-context openrouter deepseek/deepseek-r1 131072 -g
```

### `!provider set`
Kayıtlı bir sağlayıcının belirli bir alanını (endpoint, key, key-env, type) günceller.
```bash
!provider set deepseek key sk-new-secret-key -g
!provider set deepseek endpoint https://api.deepseek.com/chat/completions -g
```

### `!provider remove-model` & `!provider remove`
Belirli bir modeli veya sağlayıcıyı tamamen sistemden kaldırır.
```bash
!provider remove-model deepseek deepseek-chat -g
!provider remove deepseek -g
```

### `!model`
Aktif model rollerini (`default`, `fast`, `advanced`, `plan`, `goal`), context limitlerini ve yönlendirme durumunu gösterir veya değiştirir. Sağlayıcı ve model ismi ister boşlukla ayrı ayrı, ister `/` veya `:` ile girilebilir:
```bash
!model                                                      # Rol ve yönlendirme durumunu listeler
!model openrouter deepseek/deepseek-v4-flash                # Sağlayıcı ve modeli ayrı argümanlarla belirleme (Önerilen)
!model set default openrouter deepseek/deepseek-v4-flash -g # Varsayılan role atama (Global)
!model set fast openrouter mistralai/mistral-7b-instruct -p # Hızlı role atama (Proje düzeyi)
!model set advanced openrouter anthropic/claude-3.7-sonnet  # Gelişmiş role atama (Session only)
!model openrouter/cline-pass/deepseek-v4-flash              # Bölü (/) formatında belirleme
!model route auto                                           # Göreve göre otomatik akıllı yönlendirmeyi açar

# CONTEXT LIMIT DEĞİŞTİRME:
!model context 65536                                        # Aktif varsayılan (default) modelin context limitini değiştirir
!model context fast 32768                                   # Hızlı (fast) rolündeki modelin context limitini değiştirir
!model context advanced 200000 -g                           # Gelişmiş (advanced) modelin limitini global kaydeder
!model context cline cline-pass/deepseek-v4-flash 128000 -g # Belirli sağlayıcı/modelin context limitini günceller
```

---

## 🔁 2. Otonom Ajan, Planlama & Bütçe Komutları

### `!plan <görev açıklaması>`
Verilen görev için önce kod tabanını inceler, numaralandırılmış adım adım bir uygulama planı oluşturur ve sizden `[y/N]` onayı ister.
```bash
!plan Kullanıcı kayıt servisine rate limiting ve redis cache desteği ekle
```

### `!goal <hedef açıklaması>`
Tüm testler %100 yeşil olana ve hedef doğrulanana kadar otonom `Plan -> Act -> Verify -> Repair` döngüsünü çalıştırır.
```bash
!goal Ödeme modülündeki tüm başarısız testleri düzelt ve geçmesini sağla
```

### `!steps`
Ajanın tek bir görevdeki maksimum adım bütçesini görüntüler veya günceller.
```bash
!steps                                       # Bütçe durumunu ve uyarı eşiklerini gösterir
!steps 50                                    # Standart görev bütçesini 50 adım yapar
!steps goal 100                              # !goal otonom döngü bütçesini 100 adım yapar
!steps plan 20 -p                            # Projeye özel plan bütçesini 20 adım yapar
```

---

## 🛡️ 3. Bellek İçi Tampon, Diff & Snapshot Komutları

### `!diff`
Modelin bellek içi tamponda hazırladığı fakat henüz diske yazmadığı tüm değişiklikleri renkli diff formatında gösterir.
```bash
!diff
```

### `!apply`
Tampondaki tüm bekleyen dosya değişikliklerini atomik olarak diske kaydeder ve AST indeksini günceller.
```bash
!apply
```

### `!autoapply`
Tamponun diske otomatik yazılma politikasını belirler.
```bash
!autoapply status                            # Mevcut tampon politikasını gösterir
!autoapply manual                            # Değişiklikleri yalnızca !apply ile kaydet (Varsayılan)
!autoapply on_test                           # Test çalıştırılmadan hemen önce otomatik diske uygula
!autoapply always                            # Her model yazımında anında diske uygula
```

### `!undo` & `!rollback`
Tamponda veya diskte yapılan son değişikliği ya da belirli bir snapshot'ı geri alır.
```bash
!undo                                        # Son değişikliği geri alır
!rollback snap_20260823_193000              # Belirtilen snapshot anına geri döner
```

---

## 🌌 4. Spatiotemporal Runtime & Canlı Teşhis Komutları

### `!runtime [all | services | fibers | tools | commands]`
Spatiotemporal Composability çalışma zamanını, aktif coeffect servislerini, fiberleri ve LIFO ters işlem akümülatör derinliğini gösterir.
```bash
!runtime                                     # Kapsamlı tam teşhis paneli
!runtime fibers                              # Yalnızca fiber durumlarını gösterir
```

### `!fibers`
Sistemdeki tüm dinamik eklenti fiberlerini listeler:
- `🟢 ACTIVE`: Tüm coeffect bağımlılıkları sağlanmış ve çalışan fiberler.
- `⏳ PENDING`: Eksik servis/coeffect bekleyen fiberler (ve beklediği servis listesi).
- `🔴 FAILED`: Başlatma sırasında hata almış ve kısmi ters işlemleriyle atomik rollback uygulanmış fiberler.
```bash
!fibers
```

### `!services`
Çalışma zamanı kök bağlamına (`Runtime::Context`) sağlanan 10 çekirdek alt sistemi (`:buffer`, `:snapshot`, `:lsp`, `:ast`, `:guard`, `:sandbox`, `:adapters`, `:events`, `:config`, `:index`) ve özel servisleri listeler.
```bash
!services
```

### `!agents`
Etkileşimli ajan/fiber panosu (Plan 51): tüm fiberleri durum glifleriyle (🟢 aktif, ⏳ bekleyen, 🔴 hatalı) listeler; orkestratör fiberleri için adım ilerlemesi ve Ω ters işlem derinliğini gösterir. İnteraktif terminallerde ok tuşlarıyla fiber seçilip detay görünümü (coeffect bağımlılıkları, token kullanımı, son hata) açılır; boru/CI modunda düz liste basılır.
```bash
!agents                                      # Pano + (TTY ise) detay seçimi
```

---

## 🌳 5. Kod Zekası, AST Grafı & LSP Komutları

### `!lsp`
Dil Sunucusu Protokolü (LSP) entegrasyonunu yönetir ve anlık derleyici hatalarını inceler.
```bash
!lsp status                                  # Aktif dil sunucularını ve durumunu gösterir
!lsp on                                      # LSP motorunu açar
!lsp off                                     # LSP motorunu kapatır
!lsp diag                                    # Projedeki tüm derleyici/tip hatalarını listeler
!lsp diag lib/rubik/repl/shell.rb            # Belirli bir dosyadaki LSP teşhislerini döker
!lsp start rust                              # Rust sunucusunu (rust-analyzer) manuel başlatır
!lsp stop rust                               # Rust sunucusunu durdurur
```

### `!symbols <sorgu>`
Projedeki fonksiyon, sınıf, struct ve metot tanımlarını AST grafında semantik olarak arar.
```bash
!symbols UserValidator
!symbols complete
```

### `!outline <dosya>`
Hedef kaynak dosyanın semantik anahat ağacını (sınıflar, metotlar, satır aralıkları) döker.
```bash
!outline lib/rubik/repl/shell.rb
```

### `!refs <sembol>`
Bir sembolün tüm kod tabanındaki referanslarını ve çağrıldığı yerleri listeler.
```bash
!refs build_default
```

### `!ast <dosya | sembol>`
AST sembol detaylarını veya dosya semantik ağacını inceler.
```bash
!ast lib/rubik/tools/registry.rb
```

### `!context`
Proje bağlam indeksini yönetir.
```bash
!context status                              # İndekslenen dosya ve dil özetini gösterir
!context scan                                # Kod tabanını baştan tam tarar
!context add src/custom.rb                   # Bağlama tek bir dosya ekler
!context drop tmp/scratch.rb                 # Dosyayı bağlamdan çıkarır
```

---

## 🧪 6. Derleme, Test & Güvenli Sandbox Komutları

### `!test [dosya]`
Aktif dil adaptörü (Ruby, Python, Go, Rust, C, Zig) üzerinden testleri çalıştırır.
```bash
!test                                        # Tüm test paketini koşturur
!test test/unit/test_repl.rb                 # Tek bir test dosyasını koşturur
```

### `!lint [dosya]` & `!format [dosya]`
Sözdizim denetleyicisi veya formatlayıcıyı çalıştırır.
```bash
!lint
!format lib/rubik/config.rb
```

### `!sh <komut>`
Güvenlik katmanı (`Security::Guard`) ve süreç izolasyonu (`Sandbox::Runner`) altında güvenli kabuk komutu çalıştırır.
```bash
!sh git status
!sh cargo check
```

---

## 💾 7. Oturum, Geçmiş & Genel Ayarlar

### `!session`
Geçmiş oturumları listeler, oturum detayını görüntüler veya eski bir oturuma kaldığı yerden devam eder. İnteraktif terminallerde `!session resume` (id'siz) ok tuşlu oturum seçiciyi açar (Plan 51).
```bash
!session list                                # Kayıtlı oturumları listeler
!session resume                              # TTY: oturum seçici · boru: en son oturum
!session resume sess_20260823_180000         # Belirtilen oturumu yükler
!session info                                # Aktif oturum olay sayısını ve dosyasını gösterir
```

### `!history` & `!replay`
Oturum geçmişini inceler veya komut akışını yeniden oynatır.
```bash
!history                                     # Son komut ve istem geçmişini döker
!replay .rubik/sessions/latest.jsonl         # Oturumu adım adım baştan yürütür
```

### `!config`
Çalışma zamanı ayarlarını okur, yazar veya aktif ayar dosyası konumlarını gösterir.
```bash
!config path                                 # Global ve proje config yollarını gösterir
!config get buffer.auto_apply                # Belirli bir ayarın değerini okur
!config set buffer.auto_apply on_test        # Global config'e kaydeder
!config set buffer.auto_apply on_test -p     # Proje config'ine (.rubik/config.yml) kaydeder

# LLM STREAMING (CANLI AKIŞ) & BATCH MODU:
!config get llm.stream                       # Canlı token akışı durumunu sorgular (Varsayılan: true)
!config set llm.stream false -g              # Global olarak klasik bloklayıcı batch moduna geçer
!config set llm.stream true -g               # Global olarak canlı token akışını (streaming) etkinleştirir
```

### `!verbosity` & `!verbose`
Ajanın adım yürütme sırasındaki canlı çıktı detay düzeyini (0-3) görüntüler veya değiştirir.
- `0 - quiet`: Sıfır ara gürültü, sadece nihai yanıt ve kritik hatalar.
- `1 - normal`: Temiz, estetik adım & araç ilerleme görünümü (Varsayılan).
- `2 - verbose`: Ayrıntılı JSON argümanları, ilk 5 satır çıktı önizlemesi ve ara düşünceler (`[Thought]`).
- `3 - debug`: Ham araç girdi/çıktıları, mikrosaniyelik süreler ve teşhis bilgileri.

```bash
!verbosity                                   # Aktif ayrıntı düzeyini ve tüm seviyeleri gösterir
!verbosity quiet                             # Sessiz moda geçer (0)
!verbosity normal                            # Standart moda geçer (1)
!verbosity verbose                           # Ayrıntılı moda geçer (2)
!verbosity debug                             # Teşhis/debug moduna geçer (3)
!verbosity 2 -p                              # Projeye özel verbose seviyesini kaydeder
!verbose                                     # normal <-> verbose arasında anında toggle eder
!verbose on                                  # Verbose modunu açar
!verbose off                                 # Verbose modunu kapatır (normal'e döner)
```

### `!workspace` & `!roots`
Monorepo veya çoklu paket mimarilerinde birden fazla çalışma alanı kök dizinini dinamik olarak yönetir, listeler veya kaldırır.
```bash
!workspace list                              # Yapılandırılmış birincil ve ek kök dizinleri listeler
!roots list                                  # !workspace list ile aynıdır (alias)
!workspace add ../shared-kernel              # Salt-okunur ek kök dizin ekler ve AST indeksine katar
!workspace add ../proto --rw                 # Yazılabilir (--rw) ek kök dizin ekler
!workspace add ../contracts -p               # Projeye özel (.rubik/config.yml) kalıcı ekler
!workspace remove ../shared-kernel           # Ek kök dizini çalışma alanından çıkarır
```

### `!status`, `!commands`, `!help`, `!quit`
```bash
!status                                      # Proje adı, git dalı, model ve tampon durumu
!commands                                    # Tüm yerleşik ve dinamik komutların özeti
!help [komut]                                # Yardım çıktısı (örn: !help provider)
!quit veya !exit                             # REPL kabuğundan güvenle çıkar
```

---

## 🧬 8. Dinamik Sentezlenen Komutlar (Self-Evolving)

Rubik'te çalışan model `synthesize_command` aracını kullanarak oturum esnasında projeye özel yeni komutlar üretebilir.

Örnek: Modelin oluşturduğu `!db_seed` veya `!benchmark_api` komutu, REPL tablosuna anında kaydedilir ve doğrudan bir `!` komutu olarak çağrılabilir:

```bash
rubik (my_project) [main] > !db_seed
Seeding development database with 50 mock users... Done!
```

---

## 🛠️ 9. Doğrudan Model Araçları (Native Toolbelt) & Hedefli Düzenleme

Rubik, frontier seviyesindeki kodlama modellerinin (`Claude 3.7 / 3.5 Sonnet`, `GPT-4o`, `DeepSeek-Coder-V3/R1`, `Qwen 2.5 Coder`) yüksek başarıyla çalışması için cerrahi hedefli kod düzenleme ve Elm derleyicisi tarzı hata geri bildirimleri sunar:

### A. Hedefli Kod Düzenleme (`replace_file_content`)
Var olan dosyalarda tüm dosyayı baştan yazmak yerine sadece değişmesi gereken bloğu cerrahi olarak değiştirir:
- **Parametreler:**
  - `path`: Dosya yolu.
  - `target_content`: Değiştirilecek mevcut metin (boşluk ve girintiler birebir eşleşmelidir).
  - `replacement_content`: Yeni metin.
  - `start_line` / `end_line` *(Opsiyonel)*: Arama yapılacak satır aralığı.
  - `allow_multiple` *(Opsiyonel, default: false)*: Dosyadaki tüm eşleşmeleri topluca değiştirme.

### B. Elm Tarzı Yönlendirici Hata Mimarisi (`DiagnosticReporter`)
Bir dosya, sembol veya araç bulunamadığında model kuru bir hata yerine şunları alır:
1. **Sorun Tanımı:** Neyin neden bulunamadığı.
2. **Did you mean? (Öneri):** En yakın dosya, sembol veya araç adları (`did_you_mean` & `diff-lcs`).
3. **Actionable Next Steps:** Modelin bir sonraki adımda ne yapması gerektiğini bildiren adımlar.

### C. Otonom Araç Sentezi (`synthesize_tool`)
Model built-in araç setinde bulunmayan özel bir işlev (özel AST manipülasyonu, özel format dönüştürücü, benchmark vb.) gerektiğinde çalışma zamanında kendi aracını üreterek (`synthesize_tool`) toolbelt'e ekler.

Oturum kapandığında veya context dispose edildiğinde, spatiotemporal LIFO ters işlem mekanizması sayesinde tüm dinamik komutlar zombi referans bırakmadan temizlenir.
