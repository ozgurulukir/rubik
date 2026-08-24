# 🕹️ Rubik REPL Komut Kılavuzu (`COMMANDS.md`)

> Rubik etkileşimli REPL kabuğu içerisindeyken kod yazımı, otonom planlama, sağlayıcı yönetimi, bellek tamponu ve AST denetimi için kullanabileceğiniz tüm **Bang (`!`) Komutları**.

---

## 📑 Hızlı Erişim İndeksi

1. [Model, Sağlayıcı & Yönlendirme](#-1-model-sağlayıcı--yönlendirme-komutları) (`!provider`, `!providers`, `!model`)
2. [Otonom Ajan, Planlama & Bütçe](#-2-otonom-ajan-planlama--bütçe-komutları) (`!plan`, `!goal`, `!steps`)
3. [Bellek İçi Tampon, Diff & Snapshot](#-3-bellek-içi-tampon-diff--snapshot-komutları) (`!diff`, `!apply`, `!autoapply`, `!undo`, `!rollback`)
4. [Spatiotemporal Runtime & Teşhis](#-4-spatiotemporal-runtime--canlı-teşhis-komutları) (`!runtime`, `!fibers`, `!services`)
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
Yeni bir LLM sağlayıcısını ilk modeliyle birlikte canlı sisteme ekler ve kalıcı kaydeder.
```bash
# Doğrudan API anahtarı ile:
!provider add deepseek openai_compatible https://api.deepseek.com/v1/chat/completions --key=sk-your-key --model=deepseek-coder --context=64000

# Ortam değişkeni ile (Güvenlik / Git dostu):
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-3.5-sonnet --context=200000

# Projeye özel eklemek için:
!provider add local_vllm openai_compatible http://localhost:8000/v1/chat/completions --model=qwen2.5-coder --context=32768 -p
```

### `!provider add-model`
Mevcut bir sağlayıcıya yeni bir model daha tanımlar veya mevcut modelin context token limitini günceller.
```bash
!provider add-model deepseek deepseek-chat --context=64000
!provider add-model openrouter meta-llama/llama-3.3-70b-instruct --context=131072
```

### `!provider set`
Kayıtlı bir sağlayıcının belirli bir alanını (endpoint, api_key, api_key_env, type) günceller.
```bash
!provider set deepseek key sk-new-secret-key
!provider set deepseek endpoint https://api.deepseek.com/v2/chat/completions
```

### `!provider remove-model` & `!provider remove`
Belirli bir modeli veya sağlayıcıyı tamamen sistemden kaldırır.
```bash
!provider remove-model deepseek deepseek-chat
!provider remove deepseek
```

### `!model`
Aktif model rollerini (`default`, `fast`, `advanced`, `plan`, `goal`), context limitlerini ve yönlendirme durumunu gösterir veya değiştirir. Sağlayıcı ve model ismi ister boşlukla ayrı ayrı, ister `/` veya `:` ile girilebilir:
```bash
!model                                                      # Rol ve yönlendirme durumunu listeler
!model openrouter deepseek/deepseek-v4-flash                # Sağlayıcı ve modeli ayrı argümanlarla belirleme (Önerilen)
!model set default openrouter deepseek/deepseek-v4-flash    # Belirli bir role ayrı argümanlarla atama
!model set advanced openrouter anthropic/claude-3.5-sonnet  # Gelişmiş rol modelini ayarlama
!model openrouter/cline-pass/deepseek-v4-flash              # Bölü (/) formatında belirleme
!model deepseek-coder                                       # Aktif sağlayıcı altında model seçme
!model add openrouter cline-pass/deepseek-v4-flash --context=64000 # Sağlayıcıya yeni model ekleme
!model route auto                                           # Göreve göre otomatik akıllı yönlendirmeyi açar
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
Geçmiş oturumları listeler, oturum detayını görüntüler veya eski bir oturuma kaldığı yerden devam eder.
```bash
!session list                                # Kayıtlı oturumları listeler
!session resume                              # En son oturumu geri yükler
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

Oturum kapandığında veya context dispose edildiğinde, spatiotemporal LIFO ters işlem mekanizması sayesinde tüm dinamik komutlar zombi referans bırakmadan temizlenir.
