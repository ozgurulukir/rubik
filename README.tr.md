# Rubik

[English](README.md) | Türkçe

[![Build](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Gem sürümü](https://img.shields.io/gem/v/rubik.svg)](https://rubygems.org/gems/rubik)
[![Lisans: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ruby 3.4+](https://img.shields.io/badge/ruby-3.4%2B-red.svg)](https://www.ruby-lang.org/)
[![Kapsama raporları](https://img.shields.io/badge/coverage-CI%20artifacts-blue.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)
[![Test Suite](https://img.shields.io/badge/tests-see%20CI-blue.svg)](https://github.com/ozgurulukir/rubik/actions/workflows/ci.yml)

## Hakkında

Rubik, Ruby ile yazılmış bir terminal kodlama ajanı ve etkileşimli REPL'dir.
Yapılandırılmış bir LLM'yi çalışma alanındaki dosyaları okuma ve değiştirme
araçlarına bağlar; dosya düzenlemelerini bellekte incelemeye açık bir tamponda
tutar. Geliştiriciler Rubik'i CLI olarak kullanabilir veya `require "rubik"`
ile çalışma zamanını Ruby uygulamalarına gömebilir.

Rubik, terminalde bir kodlama ajanı isteyen ve değişikliklerin diske nasıl
uygulanacağını denetlemek isteyen geliştiriciler içindir. OpenAI uyumlu
sağlayıcıları, Anthropic'i ve yerel Ollama'yı destekler. Güvenlik denetimleri ve
isteğe bağlı işletim sistemi sandbox'ı için [Güvenlik](SECURITY.md) belgesine bakın.

## Hızlı başlangıç

**Önkoşullar:** Ruby 3.4 veya üzeri ve bu örnek için bir OpenRouter API anahtarı.
RubyGems paketini kurun:

```sh
gem install rubik
```

Anahtarı kabuk ortamınızda ayarlayın. `your-key` değerini kendi anahtarınızla
değiştirin.

Linux veya macOS:

```sh
export OPENROUTER_API_KEY="your-key"
```

PowerShell:

```powershell
$env:OPENROUTER_API_KEY = "your-key"
```

Proje dizininde Rubik'i başlatın:

```sh
rubik
```

REPL isteminde sağlayıcıyı kaydedip modeli seçin:

<!-- markdownlint-disable MD013 -->

```text
!provider add openrouter openai_compatible https://openrouter.ai/api/v1/chat/completions --key-env=OPENROUTER_API_KEY --model=anthropic/claude-sonnet-5.5 --context=200000 -g
!model openrouter/anthropic/claude-sonnet-5.5
```

<!-- markdownlint-enable MD013 -->

Geçerli dizin için bir kodlama görevi yazın. Hazırlanan değişiklikleri `!diff`
ile inceleyip `!apply` ile diske yazın. Kimlik bilgisi ayarı ve daha uzun bir
örnek için [ilk oturum öğreticisine](docs/tutorials/first-session.md), Windows
kurulumu için [kurulum rehberine](docs/how-to/installation.md) bakın.

## Özellikler

1. **Çekirdek · Çoklu platform CLI.** Terminal ajanını ve REPL'i Linux, macOS
   veya Windows'ta çalıştırın. CI; Ubuntu'yu Ruby 3.4 ve 4.0, macOS ile Windows'u
   Ruby 4.0 üzerinde kapsar. Windows CI ortamında gem kurulumu yerel bir
   bağımlılığı Rust GNU araç zinciriyle derler.
   [Kurulum rehberine](docs/how-to/installation.md) bakın.
2. **Çekirdek · Hazırlanan dosya düzenlemeleri.** Model yazımları diske hemen
   gitmez, bellekteki sanal tampona alınır. `!diff` ile inceleyin, `!apply` ile
   uygulayın veya uygulanmamış değişiklikleri `!undo` ile atın.
3. **Çekirdek · İnceleme denetimi ve yazma davranışı.** Operatör onayı zorunlu
   olsun istiyorsanız `buffer.model_can_apply: false` ile
   `buffer.auto_apply: manual` ayarlarını birlikte kullanın. Her dosya atomik
   yazılır; ancak çok dosyalı uygulama bir işlem değildir. Kısmi hatada kalan
   dosyalar tamponda kirli kalır ve uygulanan, başarısız, bekleyen dosyalar raporlanır.
   [Tampon yapılandırmasına](docs/how-to/configuration.md) bakın.
4. **Çekirdek · Birden çok çalışma alanı kökü.** Kardeş veya harici dizinleri
   varsayılan olarak salt okunur ekleyin; `--rw` ile yazma izni verin. Ek kökler
   kod aramasına ve AST indeksine katılabilir. [`!workspace` komutlarına](docs/reference/commands.md) bakın.
5. **Çekirdek · Denetimli komut yürütümü.** Komutlar Rubik'in güvenlik
   denetimlerinden geçer. Bubblewrap, Docker veya Podman yalıtımı isteğe bağlıdır
   ve varsayılan olarak kapalıdır. [Güvenlik uygulamalarına](SECURITY.md) bakın.
6. **Modeller · Sağlayıcı ve rol yönlendirme.** OpenAI uyumlu uç noktaları,
   Anthropic'i, OpenAI'ı veya yerel Ollama'yı bağlayın; sonra modelleri varsayılan,
   hızlı ve gelişmiş rollere atayın ya da göreve göre yönlendirme kullanın.
   [Sağlayıcı yapılandırmasına](docs/how-to/configuration.md) bakın.
7. **Kod zekâsı · Hibrit AST.** Ruby'yi Prism ayrıştırır; Tree-Sitter gramerleri
   Python, Go, Rust, TypeScript, TSX, JavaScript, C, C++ ve Zig'i kapsar. Sembol
   ve çağrı grafiği arka planda hazırlanabilir ve yerel önbellekte saklanır.
   Tree-Sitter kullanılamadığında Rubik yapısal sınırları olan regex çıkarıcılarına
   dönebilir. Ayrıştırma hataları yapılandırılmış durumlarla raporlanır ve başarısız
   yeniden indeksleme eski sembolleri korur. [Mimariye](docs/explanation/architecture.md) bakın.
8. **Kod zekâsı · Canlı LSP teşhisleri.** Yapılandırılmış dil sunucuları ihtiyaç
   anında başlatılabilir ve düzenlemelerden sonra derleyici/linter teşhisleri
   döndürebilir. Sunucu eksik veya hatalıysa oturum bloklanmaz; yerleşik sözdizimi
   ve AST analizi kullanılır. [Dil sunucusu kurulumuna](docs/how-to/language-servers.md) bakın.
9. **Kod zekâsı · Yerel hızlı yollar.** Ripgrep ve Git varsa arama ile bağlam
   taraması hızlanır; ikililer eksikse veya kapatılmışsa Rubik saf Ruby yoluna
   döner. `tools.native` veya `RUBIK_NATIVE` ile denetlenebilir.
   [Yapılandırmaya](docs/how-to/configuration.md) bakın.
10. **Genişletilebilirlik · Çalışma zamanı sentezi.** Model oturum sırasında
    REPL komutları ve araçlar oluşturabilir. Yönetilen çalışma zamanı etkileri
    temizleme işlemi kaydeder ve bunları LIFO sırasıyla geri alır.
    [Kendi kendini evrimleştirme rehberine](docs/explanation/self-evolution.md) bakın.
11. **Genişletilebilirlik · Eklentiler.** Kullanıcı veya proje dizinlerinden
    Ruby eklentilerini yükleyin ve yeniden yükleyin. SHA-256 manifest'leri
    değiştirilmiş dosyaları tespit eder; eklentiler ana süreçte Ruby kodu çalıştırır
    ve sandbox içine alınmaz. [Eklenti rehberine](docs/how-to/plugins.md) bakın.
12. **Genişletilebilirlik · MCP sunucuları.** Harici stdio sunucularına bağlanın
    ve keşfedilen araçları Rubik kayıt defterine ekleyin. Yaşam döngüsü temizliği,
    bağlantı kesildiğinde proxy araçlarını kaldırır ve alt süreçleri durdurmaya
    çalışır. [MCP komutlarına](docs/reference/commands.md) bakın.
13. **Kurtarma · Canlı servis onarımı.** Çalışma zamanı durumunu inceleyin,
    yedek komutu kullanımdan atılabilir bir bağlamda doğrulayın, sonra süreci
    yeniden başlatmadan devreye alın. Başarısız devreye alma veya kaydetme oturum
    değişikliklerini geri alır; önceki servis geri yüklenemezse onarım sonucu
    rollback'in tamamlanmadığını bildirir. Başarılı operatör yapılandırma
    kayıtları korunur. [Çalışma zamanı onarımına](docs/explanation/runtime-repair.md) bakın.
14. **Uzun oturumlar · Yapılandırılmış hedef defteri.** `!goal` döngüsü hedef,
    görev, bulgu ve kararları revizyon denetimli biçimde saklar; güncel durum
    sıkıştırmadan geçer, yapılandırılan doğrulamalar adım sınırlarında yeniden
    çalışır. [Hedef komutlarına](docs/reference/commands.md) bakın.
15. **Uzun oturumlar · Bağlam budayıcı.** Budayıcı tutulacak, atılacak veya
    özetlenecek içeriği önerebilir; harness planı doğrular ve tur sınırında uygular.
    `!prune` ile elle de çalıştırılabilir. [Budayıcı ayarlarına](docs/how-to/configuration.md) bakın.
16. **Uzun oturumlar · Vakanüvis kayıtları.** Yapılandırıldığında kronikçi oturum
    turlarını ve alt ajan olaylarını kaydeder; damıtıcı bellek notları ve wiki
    iskeleti oluşturabilir. [Çalışma zamanı mimarisine](docs/explanation/architecture.md) bakın.
17. **Etkileşim · Canlı izleme ve TUI.** Sessiz, normal, ayrıntılı veya debug
    çıktıyı seçin. Arayüz statusline, spinner, Markdown renderer, renkli diff
    görünümü ve etkileşimli `!agents` panosunu bir araya getirir. `NO_COLOR` ve
    pipe modunda düz metne geçilir; oturum kayıtlarında ANSI kodu bulunmaz.
    [Arayüz ayarlarına](docs/how-to/configuration.md) bakın.
18. **Çalışma zamanı · Eşzamanlı I/O.** Saf Ruby Fiber Scheduler desteklenen
    bloklayan I/O işlemlerini tek thread üzerinde örtüşmeli çalıştırabilir; CPU
    işlerini paralelleştirmez; `RUBIK_FIBER_SCHEDULER=off` ile kapatılabilir.
    Kapasite harness'i yaşam döngüsünü 1.000 epoch'ta, eşzamanlı loopback
    isteklerini 100 ve 1.000 ölçekte, AST önbelleğini ise ayrıca sınar.
    [Mimari](docs/explanation/architecture.md) ve [test rehberine](docs/development/testing.md) bakın.

## Belgeler

Öğreticiler, nasıl yapılır kılavuzları, başvuru belgeleri, mimari açıklamalar ve
geliştirme rehberleri için [belge dizinini](docs/index.md) kullanın.
[Değişiklik günlüğü](CHANGELOG.md) sürüm geçmişini içerir.

## Katkı ve politikalar

[Katkıda bulunma](CONTRIBUTING.md) · [Davranış kuralları](CODE_OF_CONDUCT.md) ·
[Güvenlik politikası](SECURITY.md) · [Lisans](LICENSE)
