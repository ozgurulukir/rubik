Rubik — Çok Dilli ve REPL Tabanlı Otonom Kodlama Ajanı

**Tarih:** 22 Ağustos 2026  
**Doküman Tipi:** Mimari Tasarım ve Sistem Önerisi (RFP / Technical Proposal)  
**Çalışma Modeli:** Etkileşimli Terminal REPL (Read-Eval-Print Loop) + Arka Plan Otonom Orkestrasyon  
**Çekirdek Motor:** Ruby 3.3+ (Orkestratör), Prism AST, Language Server Protocol (LSP) Adaptörleri, Wasm Sandbox  
**Sürüm:** 1.2 (Genişletilmiş ve Revize Edilmiş)

---

## İçindekiler

1. Yönetici Özeti  
2. Problem Tanımı ve Motivasyon  
3. Vizyon ve Temel Amaç  
4. Kapsam ve Hedefler  
5. REPL Çalışma Modeli ve Kullanıcı Deneyimi  
6. Sistem Mimarisi  
7. Temel Modüller ve Teknik Detaylar  
   7.1 REPL & Oturum Arayüzü  
   7.2 Proje Bağlam Yöneticisi  
   7.3 Çok Dilli Yürütme Adaptörleri  
   7.4 Teşhis & Kendi Kendini Düzeltme Motoru  
   7.5 LLM Entegrasyon Katmanı  
   7.6 Konfigürasyon ve Eklenti Sistemi  
8. REPL Komut Seti ve Araç Protokolü  
9. Güvenlik ve İzolasyon Protokolü  
10. Başarı Kriterleri ve Performans Metrikleri  
11. Riskler ve Azaltma Stratejileri  
12. Geliştirme Yol Haritası  
13. Kaynaklar ve Bağımlılıklar  
14. Sonuç  

---

## 1. Yönetici Özeti

**Rubik**, geliştiricilerin terminalden ayrılmadan, doğal dil komutları ve kod parçacıkları aracılığıyla çok dilli (multi-language) yazılım projelerini otonom olarak geliştirmesini, test etmesini ve onarmasını sağlayan etkileşimli bir REPL tabanlı kodlama ajanıdır. Sistem, pasif bir sohbet botu olmanın ötesine geçerek **İddia Et → Doğrula → Uygula** (Claim-Verify-Act) döngüsünü sürekli işletir; derleyici, linter, test çalıştırıcı ve dil sunucularıyla (LSP) entegre çalışarak kod üretimini doğrular, hataları otomatik onarır ve değişiklikleri kullanıcı onayına sunar.

Bu doküman, Rubik'in mimari tasarımını, temel modüllerini, güvenlik protokollerini, geliştirme yol haritasını ve başarı kriterlerini kapsamlı biçimde tanımlar. Amaç, teknik ekibe uygulanabilir bir yol haritası sunmak ve paydaşlara sistemin değerini netleştirmektir.

---

## 2. Problem Tanımı ve Motivasyon

Günümüz yazılım geliştirme süreçlerinde yapay zekâ destekli araçlar genellikle iki uçta konumlanır:

- **IDE eklentileri:** Kullanıcıyı grafik arayüze bağımlı kılar, terminal odaklı iş akışını böler ve çoğu zaman pasif tamamlama önerileriyle sınırlıdır.
- **Chat tabanlı asistanlar:** Kod üretir ancak derleme, test ve hata düzeltme döngüsünü kullanıcıya bırakır; bağlamı sürdüremez, proje genelini göremez.

Bu boşluk, özellikle **terminal merkezli çalışan**, **düşük seviyeli dillerle (Zig, C, Rust) uğraşan** ve **tekrarlı derleme-test döngülerinden yorulan** geliştiriciler için ciddi bir verimlilik kaybıdır. Mevcut araçlar ya çok geneldir ya da tek dile gömülüdür; oysa gerçek projeler çok dillidir.

**Rubik**, bu boşluğu şu şekilde doldurur:

- Terminal içinde yaşayan, durum bilgisini koruyan bir oturum kabuğu sunar.
- Dil bağımsız bir adaptör katmanıyla derleyici/linter/test araçlarını otonom yönetir.
- Üretilen her kod parçasını “önce doğrula, sonra uygula” ilkesiyle işler.
- Kullanıcıya tam kontrol sağlar: değişiklikler önce diff olarak gösterilir, onaysız diske yazılmaz.

---

## 3. Vizyon ve Temel Amaç

**Rubik**, geliştiricinin doğrudan terminal üzerinden serbest metin komutları, kod parçacıkları veya sistem yönlendirmeleri girdiği; arka planda ise hedef dilin araç zincirini (compiler, linter, test runner, package manager) otonom olarak yöneten **REPL merkezli bir yazılım mühendisliği ajanıdır**.

Sistemin ayırt edici özelliği, pasif bir sohbet botu olmak yerine; kullanıcının girdiği komutları **İddia Et → Doğrula → Uygula (Claim-Verify-Act)** döngüsünden geçiren, oturum durumunu (session state) canlı tutan, çok dilli (C, Zig, Go, Rust, Ruby, Python vb.) geliştirme yapabilen ve kendi hatalarını derleyici/linter geri bildirimleriyle onaran etkileşimli bir kabuk (shell) sunmasıdır.

**Temel amaçlar:**

- Terminalden kopmadan, doğal dil ve kod karışımıyla proje geliştirmeyi mümkün kılmak.  
- Derleme–test–hata düzeltme döngüsünü otonomlaştırarak geliştirici süresini kısaltmak.  
- Dil bağımsız bir mimariyle farklı araç zincirlerine tek arayüzden erişim sağlamak.  
- Tüm değişiklikleri denetlenebilir ve geri alınabilir kılarak güvenli bir otonomi sunmak.

---

## 4. Kapsam ve Hedefler

### 4.1 Kapsam Dahilinde

- Etkileşimli terminal REPL arayüzü (Reline tabanlı, çok satırlı girdi, geçmiş yönetimi).  
- Proje kaynak kodunun AST ve LSP tabanlı semantik indekslenmesi.  
- Çok dilli adaptör mimarisi (Zig, C, Go, Rust, Ruby, Python öncelikli).  
- LLM tabanlı planlama, kod üretimi ve kendi kendini onarma döngüsü.  
- Derleyici/linter/test çıktılarının yapılandırılmış ayrıştırılması ve hata haritalama.  
- Güvenli yürütme ortamı (Docker/Wasm sandbox, kaynak sınırlama).  
- Diff tabanlı değişiklik yönetimi ve kalıcı yazma onayı.  
- Oturum durumunun saklanması, yeniden başlatılabilmesi ve denetlenebilir loglama.

### 4.2 Kapsam Dışında

- Grafiksel IDE eklentisi veya web arayüzü (Faz 1–4 kapsamında yoktur).  
- Üretim ortamına doğrudan dağıtım (deployment) araçları.  
- Tam otomatik kod incelemesi (code review) yapan yapay zekâ (sınırlı ölçüde desteklenebilir).  
- Kuantum hesaplama, donanım tanımlama dilleri gibi niş alanlar.

### 4.3 Başarı Ölçütleri (Kısa Vadeli)

- Bir geliştirici, sıfırdan bir Zig veya Go modülünü REPL üzerinden 5 komuttan az talimatla oluşturabilmeli.  
- Derleme/test hatalarının en az %80’i, ilk 2 onarım denemesinde otomatik çözülebilmeli.  
- Tüm değişiklikler, onay öncesi diff olarak sunulabilmeli ve `!undo` ile tamamen geri alınabilmeli.  
- Sistem, 10.000 satırlık bir projede bağlam taramasını 10 saniyenin altında tamamlayabilmeli.

---

## 5. REPL Çalışma Modeli ve Kullanıcı Deneyimi

Kullanıcı, terminalde `rubik` komutunu başlattığında dinamik bir oturum ortamına girer. REPL girdileri üç kategoriye ayrılır:

1. **Serbest Metin Prompt:** *"src/ klasöründeki bellek sızıntısını bul ve Zig ile ring buffer yapısı yaz."*  
2. **Doğrudan Komut / Slash Commands:** `!test`, `!diff`, `!rollback`, `!context add ./include`  
3. **Anlık Kod Enjeksiyonu (Multi-line Buffer):** Doğrudan kod yapıştırıp *"Bunu optimize et ve derle"* diyebilme.

Aşağıdaki örnek oturum, Rubik'in tipik bir akışını göstermektedir:

```text
rubik (zig-project) [main] > !context scan
[Rubik] 14 dosya indekslendi (build.zig, src/*.zig). Dil: Zig 0.13.0 tespit edildi.
[Rubik] 32 fonksiyon, 5 struct, 2 import haritası çıkarıldı. Bağlam belleği güncellendi.

rubik (zig-project) [main] > Ring buffer implementasyonu ekle ve unit testlerini koştur.
[Rubik::Plan]
  ├─ 1. src/ring_buffer.zig oluşturulacak
  ├─ 2. build.zig dosyasına test modülü eklenecek
  ├─ 3. 'zig test' ile doğrulama yapılacak
  └─ 4. Gerekirse düzeltme döngüsü işletilecek (maks. 3 deneme)

[Rubik::Act] src/ring_buffer.zig yazılıyor...
[Rubik::Verify] 'zig test src/ring_buffer.zig' çalıştırıldı.
[Rubik::Diagnostic] HATA: src/ring_buffer.zig:24:9: error: use of undeclared identifier 'allocator'
[Rubik::Repair] Hata bağlamı analiz ediliyor... (Deneme 1/3)
[Rubik::Act] src/ring_buffer.zig güncellendi (Parametre düzeltildi).
[Rubik::Verify] 'zig test src/ring_buffer.zig' -> Başarılı! (12/12 test geçti).

rubik (zig-project) [main] > !diff
[Gözden geçirme çıktısı basılır - kullanıcı onaylarsa diske kalıcı yazılır]

rubik (zig-project) [main] > !apply
[Rubik] Değişiklikler onaylandı ve diske yazıldı.
```

**Kullanıcı Deneyimi İlkeleri:**

- **Şeffaflık:** Ajanın o an ne yaptığı, hangi komutu çalıştırdığı ve neden başarısız olduğu anlık olarak gösterilir.  
- **Kontrol:** Hiçbir kalıcı değişiklik açık onay olmadan yapılmaz. `!diff` ve `!apply` akışı zorunludur.  
- **Esneklik:** Kullanıcı istediği an araya girebilir, yönlendirebilir veya iptal edebilir.  
- **Tekrarlanabilirlik:** Tüm oturum komutları bir log dosyasına yazılır ve istenirse yeniden oynatılabilir (replay).

---

## 6. Sistem Mimarisi

Rubik, Ruby'nin dinamik süreç yönetimi ve DSL kabiliyetleri üzerine kurulu 6 katmandan oluşur. Katmanlar arası iletişim, dahili olay veri yolu (event bus) üzerinden yapılır; her katman bağımsız test edilebilir.

```text
+-----------------------------------------------------------------------+
|                       Rubik Interactive REPL                          |
|         (Reline / TUI, Prompt Parser, History State, Hooks)           |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| 1. Oturum & Bağlam Motoru (Session & Context Graph Engine)            |
|    - AST Tabanlı Semantik Tarama (Ruby/Prism, Tree-sitter)            |
|    - Git Durumu, Bağımlılık Ağacı ve Dosya İndeksi                    |
|    - Sembol Tablosu ve Referans Çözümleme                             |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| 2. Planlayıcı & Çoklu Dil Orkestratörü (Orchestration Engine)         |
|    - LLM Prompt Synthesis (Tool-Calling Schema)                       |
|    - Görevleri atomik parçalara bölme ve önceliklendirme              |
|    - Plan onayı ve revizyon döngüsü                                   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| 3. Çok Dilli Adaptör Katmanı (Language Adapters / Toolchains)        |
|    ├─ Zig/C Adapter   (zig cc, clang, -fsyntax-only, cImport)        |
|    ├─ Go Adapter      (go vet, go build, go test)                    |
|    ├─ Rust Adapter    (cargo check, cargo test)                      |
|    └─ Dynamic Sandbox (Ruby eval, Python subprocess, Docker/WASM)    |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| 4. Teşhis, Doğrulama ve Kendi Kendini Onarma (Verification Loop)       |
|    - Compiler/Linter stdout/stderr ayrıştırma                         |
|    - Hata haritalama (Line/Col, Error Code) -> Repair Loop            |
|    - Test üretimi ve regresyon kontrolü                               |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| 5. Güvenlik ve İzolasyon Katmanı (Security & Sandbox)                |
|    - Süreç izolasyonu, kaynak limitleri, ağ politikaları             |
|    - Diff onay akışı ve kritik dosya koruması                         |
|    - Denetim logu ve oturum kaydı                                     |
+-----------------------------------------------------------------------+
```

**Veri Akışı (Özet):**

1. Kullanıcı komutu REPL'de ayrıştırılır.  
2. Oturum motoru mevcut proje bağlamını (dosya indeksi, AST sembolleri, git durumu) toplar.  
3. Orkestratör, komutu atomik görevlere böler ve uygun dil adaptörünü seçer.  
4. LLM, bağlam ve araç tanımlarıyla birlikte plan üretir.  
5. Adaptör, ilgili derleyici/test komutunu çalıştırır, sonucu doğrulama motoruna iletir.  
6. Hata varsa onarım döngüsü devreye girer; başarılıysa diff kullanıcıya sunulur.  
7. Kullanıcı onayı sonrası değişiklik kalıcı hale getirilir.

---

## 7. Temel Modüller ve Teknik Detaylar

### 7.1 REPL & Oturum Arayüzü (`Rubik::REPL`)

- **Canlı Bellek & Geri Alma (Rollback):** REPL içinde yapılan her değişiklik Git indeksinden bağımsız olarak hafızada tutulur. Her işlem sonrası otomatik snapshot alınır; `!undo` veya `!rollback` ile dosyalar anında önceki duruma döner. Snapshot'lar sıkıştırılmış olarak `~/.rubik/snapshots/` altında saklanır, böylece oturum yeniden başlatılsa bile geri alınabilir.
- **Akışkan Çıktı (Streaming UI):** Ajanın o an ne düşündüğünü, hangi dosyayı değiştirdiğini ve hangi derleyici komutunu koştuğunu adım adım gösteren terminal arayüzü. Uzun süren işlemler için ilerleme çubuğu veya durum satırı gösterilir.
- **Çok Satırlı Girdi Desteği:** Kod blokları için özel bir mod (ör. `<<EOF` benzeri) ile REPL’in tek satır sınırı aşılır.
- **Komut Geçmişi ve Oturum Kaydı:** Tüm girdiler ve çıktılar oturum dosyasına (`~/.rubik/sessions/`) JSONL formatında kaydedilir. Bu sayede `!history`, `!replay` gibi komutlarla geçmişe erişim ve yeniden oynatma mümkün olur.
- **Hook Sistemi:** Belirli olaylarda (ör. dosya değişikliği, test başarısızlığı) kullanıcı tanımlı Ruby scriptleri çalıştırılabilir.

### 7.2 Proje Bağlam Yöneticisi (`Rubik::Context`)

- **Hibrit AST ve Tree-sitter Desteği:** Ruby kodları için doğrudan **Prism**, diğer diller (Zig, C, Go vb.) için **Tree-sitter** C-bağlantıları kullanılarak fonksiyon ve tip haritaları çıkarılır. Ayrıca dil sunucuları (LSP) aracılığıyla tanım referansları, çağrı hiyerarşisi ve tip bilgileri toplanır.
- **Sembol Tablosu ve Bağımlılık Grafı:** Projedeki tüm fonksiyonlar, struct'lar, import'lar ve çağrı ilişkileri bir graf veri yapısında tutulur. Bu sayede "bu fonksiyon hangi tipleri kullanıyor?" veya "hangi dosyalar bu modüle bağımlı?" sorguları hızlıca yanıtlanır.
- **Akıllı Bağlam Seçimi:** LLM'e gönderilecek bağlam, görevin kapsamına göre dinamik olarak seçilir. Örneğin bir fonksiyonun değiştirilmesi istendiğinde, yalnızca o fonksiyonun gövdesi, çağırdığı fonksiyonların imzaları ve ilgili tip tanımları gönderilir; tüm dosya değil. Bu, token tüketimini ortalama %60–80 azaltır.
- **Artımlı Güncelleme:** Dosya değişiklikleri algılandığında yalnızca etkilenen semboller yeniden taranır; tüm proje baştan indekslenmez. Dosya izleme için `listen` gem'i veya inotify kullanılır.
- **Kontekst Önbelleği:** Sık kullanılan bağlam parçaları, oturum boyunca bellekte tutulur ve LLM isteklerinde tekrar kullanılır. Böylece aynı proje için tekrarlanan tarama maliyeti düşer.

### 7.3 Çok Dilli Yürütme Adaptörleri (`Rubik::Adapters`)

Her dil için standardize edilmiş bir arayüz tanımlanır. Adaptörler, Ruby sınıf hiyerarşisiyle değil, **kompozisyon ve strateji deseni** ile yönetilir; yeni bir dil eklemek için yalnızca `BaseAdapter` metodlarını uygulayan bir sınıf yazmak ve konfigürasyona kaydetmek yeterlidir.

```ruby
class BaseAdapter
  def check_syntax(file_path); raise NotImplementedError; end
  def compile(entry_point);    raise NotImplementedError; end
  def run_tests(filter = nil); raise NotImplementedError; end
  def parse_errors(stderr);    raise NotImplementedError; end
  def format_code(source);     raise NotImplementedError; end  # Yeni eklenen
  def dependencies;            raise NotImplementedError; end  # Yeni eklenen
end
```

**Mevcut adaptörler:**

- **Zig / C:** Derleme adımlarında `zig build-exe -fno-emit-bin` gibi anlık dry-run komutları kullanılır; derleyici hataları regex motoruyla yakalanıp satır bazlı LLM prompt'una dönüştürülür. `zig fmt` ile kod formatlama yapılabilir.
- **Go / Rust:** `go vet`, `cargo check`, `cargo test` ile saniyeler içinde tip doğrulaması yapılır. `go fmt`, `cargo fmt` desteklenir.
- **Ruby / Python:** Doğrudan `ruby -c`, `python -m py_compile` ile sözdizimi kontrolü; `rspec`, `pytest` ile test çalıştırma. Ruby için Prism AST, Python için ast modülü kullanılır.
- **Dinamik Sandbox Adaptörü:** Docker veya Wasm (ör. wasmtime) içinde güvenli çalıştırma sağlar. Özellikle derleme gerektirmeyen dillerde hızlı deneme yapmak için kullanılır.

**Adaptör Seçimi:** Proje kökündeki `rubik.yml` veya otomatik algılama (dosya uzantıları, build dosyaları) ile belirlenir. Birden fazla dil varsa, görev bazında uygun adaptör seçilir.

### 7.4 Teşhis & Kendi Kendini Düzeltme Motoru (`Rubik::SelfRepair`)

- Test veya derleme başarısız olduğunda sistem hemen kullanıcıya hata fırlatmaz.
- Belirlenen bütçeye kadar (varsayılan: 3 deneme) hata mesajını, etkilenen kod satırlarını ve AST bağlamını LLM'e göndererek yamayı (diff/patch) üretir, uygular ve yeniden test eder.
- **Hata Sınıflandırma:** Derleyici/linter çıktıları; sözdizimi hatası, tip hatası, tanımsız referans, bellek güvenliği ihlali, test başarısızlığı gibi kategorilere ayrılır. Her kategori için farklı onarım stratejisi ve prompt şablonu uygulanır.
- **Bağlamsal Onarım:** Hata satırının çevresi (önceki/sonraki 10 satır) ve ilgili sembol tanımı LLM'e eklenir. Böylece model yalnızca hatayı değil, hatanın nedenini de görebilir.
- **Yama Üretimi ve Uygulama:** Onarım önerisi, unified diff formatında üretilir ve mevcut dosyaya uygulanmadan önce hafıza içi kopya üzerinde test edilir. Başarılıysa kullanıcıya sunulur; başarısızsa bir sonraki denemeye geçilir.
- **Regresyon Kontrolü:** Yapılan her onarımın ardından yalnızca hedeflenen test değil, projedeki tüm test paketi (veya en azından etkilenen modülün testleri) çalıştırılarak yan etki olup olmadığı kontrol edilir.

### 7.5 LLM Entegrasyon Katmanı (`Rubik::LLM`)

Bu katman, Rubik'in zekâsını sağlayan kritik bileşendir ve aşağıdaki özellikleri içerir:

- **Model Sağlayıcı Soyutlama:** OpenAI, Anthropic, Google Gemini gibi bulut modellerinin yanı sıra yerel modeller (Ollama, llama.cpp) desteklenir. Model seçimi konfigürasyondan yapılır; aynı arayüz üzerinden farklı modellere geçilebilir.
- **Tool-Calling (Fonksiyon Çağrısı) Şeması:** LLM'e, yapabileceği eylemler (dosya oku, dosya yaz, komut çalıştır, test başlat vb.) JSON Schema formatında tanıtılır. Model, planını bu araçları kullanarak ifade eder. Orkestratör, bu çağrıları güvenlik katmanından geçirerek uygular.
- **Akıllı Prompt Sentezi:** Görev, proje bağlamı, hata mesajları ve geçmiş denemeler bir araya getirilerek optimize edilmiş bir prompt oluşturulur. Gereksiz bilgi gönderilmez; bağlam yöneticisinden gelen sembol ve kod parçaları kullanılır.
- **Model Yönlendirme (Routing):** Basit görevler (sözdizimi hatası düzeltme, kod formatlama) hızlı ve ucuz modellerle; karmaşık tasarım görevleri ise daha güçlü modellerle yapılabilir. Bu, maliyet ve gecikmeyi optimize eder.
- **Yanıt Doğrulama:** LLM'den dönen kod parçaları, uygulanmadan önce sözdizimi kontrolünden geçirilir. Eğer model hatalı kod üretirse, bu hata doğrulama motoruna iletilir ve düzeltme döngüsü tetiklenir.
- **Prompt Enjeksiyon Koruması:** Kullanıcı girdileri ve proje dosyalarındaki metinler, LLM'e gönderilmeden önce özel belirteçlerle ayrıştırılır; modelin sistem talimatlarını geçersiz kılmasını önlemek için şablonlar kullanılır.

### 7.6 Konfigürasyon ve Eklenti Sistemi (`Rubik::Config` & `Rubik::Plugins`)

- **Proje Bazlı Yapılandırma:** Her proje köküne `rubik.yml` dosyası eklenebilir. Bu dosyada kullanılacak dil adaptörleri, test komutları, yasaklı dosyalar, model tercihi, onarım deneme sayısı gibi ayarlar tanımlanır.
- **Küresel Yapılandırma:** Kullanıcı seviyesinde `~/.rubik/config.yml` ile varsayılanlar belirlenir.
- **Eklenti Mimarisi:** Ruby gem'leri olarak dağıtılan eklentiler, yeni dil adaptörleri, yeni komutlar, özel doğrulama kuralları veya LLM sağlayıcıları ekleyebilir. Örneğin, bir kullanıcı `rubik-plugin-ruby` gem'ini kurarak Ruby'ye özel gelişmiş özellikleri etkinleştirebilir.
- **Komut Takma Adları:** Sık kullanılan komutlar için kullanıcı tanımlı kısayollar oluşturulabilir (`alias rt="!test"` gibi).

---

## 8. REPL Komut Seti ve Araç Protokolü

Aşağıdaki tablo, Rubik REPL'inde desteklenen komutları genişletilmiş biçimde listeler. Komutlar büyük/küçük harf duyarlıdır ve `!` önekiyle başlar.

| Komut | Açıklama |
| --- | --- |
| `!help [komut]` | Tüm komutları veya belirli bir komutun yardımını gösterir. |
| `!context scan` | Proje kökündeki dosyaları tarar, sembol tablosunu ve bağımlılık grafını oluşturur. |
| `!context add <yol>` | Bağlam taramasına ek dosya/klasör ekler. |
| `!context drop <yol>` | Bağlamdan dosya/klasör çıkarır. |
| `!context status` | Mevcut bağlam özetini (dosya sayısı, sembol sayısı, son tarama zamanı) gösterir. |
| `!plan <görev>` | Görevi analiz eder ve uygulanacak adımları kullanıcıya sunar; onay ister. |
| `!diff` | Ajanın hafızasında hazırladığı ancak henüz diske yazılmamış değişiklikleri gösterir. |
| `!apply` | Yapılan değişiklikleri onaylayıp diske yazar. |
| `!undo` | Son işlemi geri alır, dosya sistemini önceki snapshot'a döndürür. |
| `!rollback <snapshot_id>` | Belirtilen snapshot'a geri döner. |
| `!test [hedef]` | Projenin test paketini tetikler ve çıktıları yakalar. |
| `!lint [hedef]` | İlgili dilin linter'ını çalıştırır (örn. `golangci-lint`, `clippy`, `rubocop`). |
| `!format [hedef]` | Kaynak kodu standart formata dönüştürür (örn. `gofmt`, `rustfmt`, `zig fmt`). |
| `!sh <komut>` | Kum havuzu içinde doğrudan kabuk komutu çalıştırır. |
| `!model [isim]` | Aktif LLM modelini değiştirir veya mevcut modeli gösterir. |
| `!session save <ad>` | Geçerli oturumu kaydeder. |
| `!session load <ad>` | Kaydedilmiş bir oturumu geri yükler. |
| `!history [n]` | Son n komutu listeler. |
| `!replay <oturum_dosyası>` | Bir oturum kaydını yeniden oynatır (deterministik olmayan LLM yanıtları nedeniyle tamamen aynı olmayabilir). |
| `!config get|set <anahtar> <değer>` | Çalışma anında yapılandırma değiştirir. |
| `!status` | Oturum, proje, aktif adaptör ve son işlem hakkında özet bilgi verir. |
| `!quit` / `!exit` | REPL'den çıkar (kaydedilmemiş değişiklikler varsa uyarır). |

**Araç Protokolü (Tool-Calling):** Orkestratör ile LLM arasındaki etkileşim, JSON tabanlı bir araç çağrı protokolü ile yapılır. Her araç, ad, açıklama, parametre şeması ve güvenlik seviyesi (okuma, yazma, yürütme) içerir. Örneğin:

```json
{
  "tool": "run_command",
  "params": {
    "command": "zig test src/ring_buffer.zig",
    "timeout": 30,
    "allow_network": false
  }
}
```

---

## 9. Güvenlik ve İzolasyon Protokolü

Güvenlik, Rubik'in temel tasarım ilkelerinden biridir. Aşağıdaki mekanizmalar, hem kullanıcıyı hem de sistemi olası zararlardan korur:

1. **Çalıştırma İzolasyonu:**  
   - Derleme ve çalıştırma adımları, izole bir alt süreçte (subprocess) veya Docker container içinde sınırlandırılmış CPU/RAM limitleriyle koşturulur.  
   - Varsayılan olarak ağ erişimi kapalıdır; yalnızca kullanıcı açıkça izin verirse açılır (`!config set network.allow true`).  
   - Dosya sistemi erişimi yalnızca proje kökü ve geçici dizinlerle sınırlanır (chroot veya bind mount ile).  
   - Süreçler, süre aşımı (timeout) ve kaynak tüketimi (RLIMIT) ile sınırlandırılır; aşım durumunda otomatik sonlandırılır.

2. **Kritik Dosya Koruması:**  
   - `.git`, `.env`, `secrets.*`, `*.pem`, `*.key` gibi dosyalar ve dizinler varsayılan olarak yazma korumalıdır.  
   - Bu dosyalarda değişiklik yapılması yalnızca kullanıcıdan açık onay (`y/n` + gerekirse güçlü doğrulama) alındığında mümkündür.  
   - Okuma erişimi bile sınırlandırılabilir; `!context add` ile yalnızca belirli dosyalar taranabilir.

3. **Kalıcı Yazma Öncesi Diff:**  
   - Ajan doğrudan dosyaların üzerine yazmaz; önce REPL hafızasında diff üretir.  
   - Doğrulama testleri geçtikten sonra diff kullanıcıya gösterilir. Kullanıcı `!apply` demeden hiçbir değişiklik diske yazılmaz.  
   - `!undo` ile son işlem her zaman geri alınabilir; snapshot mekanizması sayesinde daha eski durumlara dönüş mümkündür.

4. **Denetim ve Loglama:**  
   - Tüm komutlar, LLM istekleri, araç çağrıları ve sonuçları `~/.rubik/audit.log` dosyasına JSON formatında kaydedilir.  
   - Loglar, gerektiğinde adli analiz için kullanılabilir; hassas bilgiler maskelenir (örn. API anahtarları).

5. **Prompt Enjeksiyon ve Zararlı Kod Koruması:**  
   - Kullanıcı girdileri, LLM'e gönderilmeden önce özel etiketlerle işaretlenir; modelin sistem talimatlarını geçersiz kılma girişimleri engellenir.  
   - Üretilen kodlar, sözdizimi kontrolünden geçirilir ve bilinen tehlikeli desenler (ör. `rm -rf /`, dış ağ bağlantıları) taranır.  
   - Yürütme öncesi, komutun risk seviyesi değerlendirilir; yüksek riskli komutlar için kullanıcıdan ek onay istenir.

---

## 10. Başarı Kriterleri ve Performans Metrikleri

Rubik'in başarısı aşağıdaki ölçütlerle değerlendirilecektir:

| Metrik | Hedef | Ölçüm Yöntemi |
| --- | --- | --- |
| **Görev Tamamlama Oranı** | Kullanıcı tarafından verilen kodlama görevlerinin %85'i, 3 onarım denemesi içinde başarıyla tamamlanmalı | Entegrasyon testleri ve kullanıcı çalışmaları |
| **Ortalama Onarım Süresi** | Bir derleme/test hatasının otomatik düzeltilmesi 60 saniyeden kısa sürmeli | Zamanlama logları |
| **Bağlam Tarama Süresi** | 10.000 satırlık projede tam tarama < 10 saniye, artımlı güncelleme < 2 saniye | Benchmark |
| **Token Verimliliği** | LLM'e gönderilen bağlam, ham proje boyutunun %30'unu geçmemeli | Token sayaçları |
| **Kullanıcı Onay Oranı** | Kullanıcıların `!apply` öncesi diff'i reddetme oranı %25'in altında olmalı | Kullanım istatistikleri |
| **Güvenlik Olayı** | Hiçbir kritik dosya izinsiz değiştirilmemeli, sandbox dışına çıkış olmamalı | Denetim logları, sızma testleri |

---

## 11. Riskler ve Azaltma Stratejileri

| Risk | Etki | Olasılık | Azaltma Stratejisi |
| --- | --- | --- | --- |
| **LLM Yanlış veya Güvensiz Kod Üretimi** | Yüksek | Orta | Sözdizimi ve güvenlik taraması; tüm değişikliklerin diff onayı; kapsamlı test döngüsü |
| **Sandbox Kaçışı** | Kritik | Düşük | Çok katmanlı izolasyon (Docker + seccomp + kaynak limitleri); düzenli güvenlik denetimleri |
| **Performans Darboğazı (Büyük Projeler)** | Orta | Orta | Artımlı bağlam güncelleme; önbellekleme; adaptörlerde paralel işlem |
| **Model Bağımlılığı ve Maliyet** | Orta | Yüksek | Model sağlayıcı soyutlama; yerel model desteği; model yönlendirme ile maliyet optimizasyonu |
| **Kullanıcı Benimseme Zorluğu** | Orta | Orta | Sezgisel REPL arayüzü; kapsamlı dokümantasyon; örnek oturumlar |
| **Çok Dilli Adaptör Karmaşıklığı** | Orta | Yüksek | Standart arayüz; eklenti mimarisi; kademeli adaptör geliştirme (önce Zig/C, sonra diğerleri) |

---

## 12. Geliştirme Yol Haritası

```text
Faz 1: Çekirdek REPL & Oturum Motoru (2 Hafta)
  ├── Reline tabanlı terminal kabuğu ve komut ayrıştırıcı
  ├── Git durum takibi ve bellek içi dosya tamponu (buffer)
  ├── Snapshot ve geri alma mekanizması
  └── Temel oturum loglama

Faz 2: LLM Tool-Calling & Context Engine (3 Hafta)
  ├── Model orkestrasyonu (Plan -> Act -> Verify şeması)
  ├── Tool-calling JSON şema tanımları ve sağlayıcı adaptörleri (OpenAI, Ollama)
  ├── AST tabanlı semantik bağlam yöneticisi (Prism, Tree-sitter)
  └── Akıllı bağlam seçimi ve token optimizasyonu

Faz 3: Çok Dilli Adaptörler (3 Hafta)
  ├── Zig, C, Go ve Rust için Toolchain adaptörleri
  ├── Compiler stderr parser ve otomatik teşhis formatlayıcıları
  ├── LSP entegrasyonu (en az 2 dil için)
  └── Formatlama ve lint araçları desteği

Faz 4: Sandbox & İleri Seviye Düzeltme (2 Hafta)
  ├── Docker / Wasm tabanlı güvenli çalıştırma ortamı
  ├── Çok adımlı hata ayıklama ve regresyon test döngüsü
  ├── Kritik dosya koruması ve diff onay akışının sıkılaştırılması
  └── Denetim logu ve güvenlik testleri

Faz 5: Eklenti Sistemi ve Topluluk Hazırlığı (2 Hafta)
  ├── Ruby gem tabanlı eklenti mimarisi
  ├── `rubik.yml` konfigürasyon standardı
  ├── Örnek eklenti ve dokümantasyon
  └── Kullanıcı kabul testleri ve performans benchmark'ları
```

**Toplam süre:** 12 hafta (çekirdek ekip için). Fazlar paralelleştirilebilir; örneğin Faz 3 ile Faz 4 kısmen eş zamanlı yürütülebilir.

---

## 13. Kaynaklar ve Bağımlılıklar

### 13.1 Teknoloji Bağımlılıkları

- **Ruby 3.3+** (orkestratör dil)  
- **Prism** (Ruby AST ayrıştırıcı)  
- **Tree-sitter** (çok dilli ayrıştırma, C bağlantıları)  
- **Reline** (terminal satır düzenleme)  
- **Docker / Podman** (sandbox)  
- **Wasmtime** (Wasm sandbox, opsiyonel)  
- **Git** (sürüm kontrolü ve diff üretimi)  
- **Dil araç zincirleri:** Zig, GCC/Clang, Go, Rust, Ruby, Python (proje ihtiyacına göre)  

### 13.2 İnsan Kaynağı

- 1 Kıdemli Ruby geliştirici (orkestratör ve REPL)  
- 1 Sistem/dil uzmanı (adaptörler, derleyici entegrasyonu)  
- 1 Yapay zekâ/LLM entegrasyon uzmanı (prompt mühendisliği, tool-calling)  
- 1 Kalite güvence uzmanı (testler, güvenlik denetimleri) – yarı zamanlı  

### 13.3 Altyapı

- Geliştirme ortamı: Linux/macOS, CI/CD (GitHub Actions)  
- Test ortamı: Çeşitli dil sürümlerini içeren Docker imajları  
- LLM API erişimi (OpenAI vb.) veya yerel model sunucusu (Ollama)  

---

## 14. Sonuç

**Rubik**, Ruby’nin yüksek seviyeli dil esnekliğini, güçlü metin/süreç yönetimini ve dinamik mimarisini arkasına alarak; geliştiricilere terminalden kopmadan, herhangi bir dilde güvenli ve otonom kod geliştirme imkânı sunar. REPL yaklaşımı, geliştiriciyi süreçten koparmadan kontrolü elinde tutmasını sağlarken, ajanın kendi kendini onarma döngüsü geliştirme süresini önemli ölçüde kısaltır.

Bu doküman, sistemin mimari vizyonunu, teknik bileşenlerini, güvenlik önlemlerini ve uygulanabilir bir yol haritasını ortaya koymaktadır. Rubik, yalnızca bir kod üretici değil; **terminalde yaşayan, projeyi anlayan, doğrulayan ve onaran bir yazılım mühendisliği ortağıdır.** 

Önerilen mimari, modüler ve genişletilebilir yapısı sayesinde gelecekteki dil ve araç entegrasyonlarına açık olup, geliştirici topluluğunun ihtiyaçlarına göre şekillenebilir. Başarı kriterleri ve risk yönetimi çerçevesi, projenin ölçülebilir ve sürdürülebilir bir şekilde hayata geçirilmesini sağlayacaktır.

---

**Hazırlayan:** [Ekip/İsim]  
**İletişim:** [E-posta]  
**Dağıtım:** Teknik Ekip, Proje Paydaşları  

---

Bu sürüm, orijinal önerinin ana hatlarını korurken; eksik LLM entegrasyonu, konfigürasyon, eklenti mimarisi, başarı kriterleri, risk analizi gibi bölümleri ekleyerek dokümanı daha profesyonel ve uygulanabilir hale getirmiştir. Ayrıca REPL komut setini zenginleştirmiş, güvenlik protokollerini detaylandırmış ve teknik derinliği artırmıştır.