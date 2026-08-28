# 53 — Ajan Yüzeyi Kontratı: İzleyici Sınıflandırmalı Komut Görünürlüğü ve Genişletilmiş Ajan Erişimi

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Uygulandı** · **Zorluk:** Kolay–Orta · **Faz:** 5 (Ajan Yüzeyi ve Kontrat)  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [12](12-guvenlik-diff-onay.md), [21](21-llm-komut-sentezi-ve-calistirma.md), [36](36-repl-komut-ve-yerel-arac-ayrimi-ve-ajan-yonlendirme-guardrail.md), [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md), [43](43-repl-bang-komut-standardizasyonu-ve-wiring-denetimi.md), [45](45-spatiotemporal-oz-evrilen-calisma-zamani-ve-otonom-adaptor-sentezi.md), [47](47-orchestrator-loopun-reaktif-sistem-fiberina-donusturulmesi.md)  
> **Kapsam:** `lib/rubik/repl/shell.rb`, `lib/rubik/repl/commands/*.rb` (yalnız `audience:` bayrağı eklemeleri), `lib/rubik/tools/builtins.rb` (yalnız `ExecReplCommandTool`), `lib/rubik/prompt/context_builder.rb`, `lib/rubik/repl/commands/agent.rb` (tek satır, §5-F), test paketi  
> **Ön Çalışma:** 27 Ağustos 2026 oturum analizi — REPL komut erişim denetiminin üç katmanlı incelenmesi ve Plan 36 salınım teşhisi (§2)

---

## 🎯 1. Hedef ve Gerekçe

Plan 36, modelin hayali REPL komutları çağırıp (`!review`, `!check`) sonsuz komut döngüsüne girdiği gerçek bir sorunu çözdü; ancak çözüm dozunu kaçırdı: **38 komutun kılavuzsuz dökülmesinden, modelin komutların varlığından tamamen habersiz olmasına** savruldu. Kullanıcı teşhisi doğru: *"Plan 36'daki kısıtlama biraz fazla oldu."*

Bu plan salınımı "küratörlü görünür küme + kayıt anında tip'li kontrat"ta sabitler ve **ajanın alanını ölçülü biçimde genişletir**:

1. **Kontrat katmanında sınıflandırma:** `register_command` artık komutun kitlesini (`audience: :human | :agent | :both`) bildirir. Görünürlük ve zorlama tek doğruluk kaynağından üretilir; elle tutulan liste drift'i biter.
2. **Ajan yüzeyi genişletilir:** 7 meta komuttan, araç karşılığı **olmayan** 17 tanısal/çalışma zamanı komutuna (`!diff`, `!undo`, `!rollback`, `!context`, `!lint`, …). Bu, AGENTS.md'in "self-evolving runtime" ve "revertible effects" ideallerinin ajan yüzeyine taşınmasıdır (§3).
3. **Eksik guardrail'lar kapanır:** `!quit`/`!exit`/`!clear`/`!reset` bugün model için bloklu değildir — model kullanıcının oturumunu durdurabilir, geçmişi silebilir. Plan 36 insan-komutlarını prompt'tan sakladı ama asıl korunması gerekenleri çalışma zamanında korumasız bıraktı.
4. **History sızıntısı kapatılır:** `conversation_history`'ye literal `!goal <metin>` yazılması, sistemin "REPL komutları yasak" dediği bağlamda modele bang sözdizimini öğreten tek sızıntı noktasıdır (`agent.rb:200`).

---

## 🔍 2. Mevcut Durum Tanısı (27 Ağustos 2026 ölçümü)

### 2.1 Üç Katmanlı Mevcut Mekanizma

| Katman | Konum | Davranış |
| :--- | :--- | :--- |
| Prompt görünürlüğü | `context_builder.rb:112` (`build_commands_xml`) | Yalnız `custom: true` komutlar `<custom_commands>` olarak girer; ~45 built-in komutun hiçbiri modelle paylaşılır. Kural 4 (`:107`) `exec_repl_command`'ı "sıkı sıkıya" 7 komutla sınırlar. |
| Yönlendirme | `builtins.rb:729` (`REDIRECT_MAP`) | 9 komut (`!test`, `!sh`, `!read`, `!write`, `!apply`, `!symbols`, `!outline`, `!refs`, `!ast`) doğal araca yönlendirilir. |
| Reentrancy | `builtins.rb:766` | `!plan`/`!goal` bloklanır (ajan zaten döngü içindedir) — doğru koruma, ama mesaj yönlendirme içermez. |

### 2.2 Tespit Edilen Sorunlar

| # | Sorun | Kanıt | Sınıf |
| :--- | :--- | :--- | :--- |
| S-1 | **`!diff` kör noktası:** düzenleme akışı buffer tabanlı; sistem prompt "⚠️ N unapplied buffer changes" uyarısı basar ama modelin bekleyen değişiklikleri görmenin hiçbir yolu yok (diff aracı yok, `!diff` izinli listede değil). İroni: goal bitince kabuk kullanıcıya *"Tip: Use `!diff`"* der (`agent.rb:206`) — ajanın görmesi yasak komutu. | `context_builder.rb:107`, `agent.rb:206` | Aşırı kısıt |
| S-2 | **Allowlist drift:** kural 4 ve araç açıklaması aynı 7 komutu iki yerde elle tutar; oysa çalışma zamanı `!status`, `!context`, `!diff` gibi komutları da geçirmektedir. Plan 36'nın kendi test planı bile `!status`/`!context`'in çalıştığını doğrular. | `context_builder.rb:107` ↔ `builtins.rb:747` | Kontrat tutarsızlığı |
| S-3 | **History sızıntısı:** goal koşusu sonrası `conversation_history`'ye `{ role: "user", content: "!goal #{goal_text}" }` yazılır; sonraki turda bu geçmiş modele girer (`loop.rb:79`). Model, kullanıcı geçmişinde literal bang komutu görürken sistem prompt "REPL komutları yasak" der — çelişki + taklit daveti. | `agent.rb:200` | Prompt bütünlüğü |
| S-4 | **Eksik sert bloklar:** `!quit`, `!exit` (kabuğu durdurur), `!clear`, `!reset` (geçmişi siler) model için çalışma zamanında engelsizdir. | `commands/system.rb` (oturum kontrolü kayıtları) | Güvenlik boşluğu |
| S-5 | **Yasaklayıcı dil + eksik yönlendirme:** kural 1 "hayali komut arama" yasağı bütün REPL yüzeyini kirletir; `!plan`/`!goal` blok mesajı modele ne yapacağını söylemez; `!diagnostics`'ın araç karşılığı (`lsp_diagnostics`) REDIRECT_MAP'te yoktur. | `context_builder.rb:105`, `builtins.rb:766` | Davranış kalitesi |

### 2.3 Token Ekonomisi

Plan 36'nın kaldırdığı döküm: ~45 komut, kılavuzsuz, 400+ token. Bu planın önerisi: **17 komut, tek satırlık açıklama, hedef ≤ 250 tahmini token** (D-7). Döngüye neden olan görünürlüğün kendisi değil, kullanım kılavuzu olmayan dökümdü.

---

## 🏛️ 3. AGENTS.md Hizalaması

Bu plan yalnızca bir prompt ayarı değil; AGENTS.md'in iki idealinin **ajan yüzeyine** taşınmasıdır:

| Plan 53 Mekanizması | AGENTS.md İdeali | Madde |
| :--- | :--- | :--- |
| `audience:` bayrağı — komut kayıt anında tip'li görünürlük kontratı bildirir; ambient kayıt dökümü kalkar | **Explicit Coeffect Specifications** — bileşen tiplenmemiş global kayıt sorgulamaz; gereksinimleri açıkça bildirir | §1.B (+§5 *Implicit Global Singletons* anti-pattern'i) |
| `!diff`, `!undo`, `!rollback` ajan-görünür: Ω akümülatörü ve anlık görüntüler ajan tarafından gözlemlenebilir/tetiklenebilir | **Revertible Effects** — ters işlemler LIFO birikir; geri alma ses temelli olarak görünürdür | §1.A |
| Çok adımlı başarısız bir düzenlemede ajan `!undo`/`!rollback` ile kendi kısmi değişikliklerini geri alır | **Failure Reversibility** — yarıda kalan aktivasyon anında geri sarılır | §1.A |
| `!config`, `!model`, `!providers`, `!context compact`, `!steps` restartsız çalışma zamanı yeniden yapılandırması | **Zero-Downtime Tool Swapping / Self-Evolving Runtimes** | §3.1 (+§5 *Destructive Process Restarts*) |
| `!quit`/`!exit`/`!clear`/`!reset` için sert blok — ajan tek kullanımlık alt-bağlamda yaşar, kullanıcının oturumunu yok edemez | **Session Isolation** — deneysel/sentetik davranış atılabilir alt-bağlama hapsedilir | §3.4 |
| `!allow`/`!workspace`/`!provider` yalnız-insan: dış dizin ve kimlik bilgisi kabiliyeti **ortam tarafından** bağlanır; ajan kendine yetki veremez | **Context-Mediated Operations** — koefektler bağlam tarafından karşılanır (Σ ⊢ C : τ), bileşen tarafından kendisine atanmaz | §1.B |
| Yeni bloklar ve görünürlük filtreleri saf kapılardır; Ω'ya yeni etki kaydetmez, mevcut `on_dispose` terslerini bozmaz | **Locality of Disposal** | §6 checklist |
| Yönlendirme/steering deterministik ve kayıt anında sabittir | **Deterministic Tool Registration** | §3.2 |

---

## 📐 4. Kararlar

- **D-1 — `audience:` kontratı:** `register_command(name, description:, custom: false, audience: nil, &handler)`. `nil` → `custom ? :both : :human` (geriye dönük uyum: mevcut ~45 çağrı sitesinden yalnız genişletilecekler dokunulur). Değer kümesi `{ :human, :agent, :both }` dışı `ArgumentError`. Meta `@commands[name][:audience]` olarak saklanır.
- **D-2 — Ajan-görünür küme (17 komut, tümü `audience: :both`):** `diff`, `status`, `undo`, `rollback`, `autoapply` (buffer/ters-etki yüzeyi) · `context`, `steps` (öz-yönetim) · `config`, `model`, `providers` (restartsız yeniden yapılandırma) · `runtime`, `fibers`, `services`, `agents` (koefekt/fiber içgözlemi) · `lint`, `format` (adaptör doğrulama/onarım) · `history` (kabuk turna geçmişi). `!provider` **dahil değil** (`--key=` kimlik bilgisi yönetimi insan-yetkisidir).
- **D-3 — Zorlama sırası tek kapıda:** `ExecReplCommandTool#execute` denetim sırası: ① `REDIRECT_MAP` → ② oturum kontrolü (`quit/exit/clear/reset`) sert blok → ③ `plan/goal` blok + yönlendirme → ④ kayıtlı ama `:human` → kitle steering'i → ⑤ kayıtsız → mevcut yapısal yönlendirme → ⑥ çalıştır. Çalıştırma yolundaki `StringIO` çıktı yakalama olduğu gibi kalır (oturum izolasyonu).
- **D-4 — REDIRECT_MAP güncelleması:** `+ "diagnostics" => "lsp_diagnostics"`. Savunmacı `read`/`write` girişleri kalır (kayıtlı olmasalar da zararsız).
- **D-5 — Prompt tek kaynak:** `build_commands_xml` iki bölüm üretir: `<agent_commands>` (built-in, `audience != :human`) + mevcut `<custom_commands>` (semantiği ve testleri korunur). Kural 4'ün komut listesi **kabuk metaverisinden üretilir** (`build_operational_rules_xml(shell)`); `ExecReplCommandTool` açıklamasındaki statik 7'li liste kaldırılır, `<agent_commands>` referansıyla değiştirilir. Statik çift kopya kalmaz.
- **D-6 — Kural dili olumluya:** Kural 1'in "hayali komut arama" yasağı tek cümleye indirilir ("aracın ya da listedeki komutun karşılığı yoksa yapısal incele: `list_files`, `grep_search`"); kural 4 pozitif çerçeveye döner ("tanısal/çalışma zamanı komutların `<agent_commands>`'ta listelenir; dosya, kod, test ve kabuk işlemleri her zaman doğrudan araçlarla").
- **D-7 — Token bütçesi:** `<agent_commands>` bölümü ≤ **250** tahmini token (`TokenEstimator`); kabul testi bu eşiği pinler.
- **D-8 — History sızıntısı:** `agent.rb:200` → `content: "Goal: #{goal_text}"`. Oturum kayıtçısı ham komutu zaten ayrı tutar (`agent.rb:174` `record_user_turn("!goal …")`) — replay bütünlüğü bozulmaz, LLM bağlamına bang sözdizimi sızmaz.
- **D-9 — Yeni etkiler yok:** Bu plan Ω'ya yeni ters işlem kaydetmez; yalnız sınıflandırma, kapı ve prompt üretimidir (§6 checklist yerelliği).
- **D-10 — `!undo` ajan-görünürlüğü bilinçli kabul:** Goal koşusu sırasında ajanın kendi ara yazışlarını geri alabilmesi özelliktir (§1.A Failure Reversibility). `auto_apply` etkileşimi dokümante edilir, bloklanmaz. `!model` geçişinin etkinliği bir sonraki run'da başlar (provider run başında bağlanır); dokümante edilir.

### 4.1 Nihai Erişim Matrisi (~45 komut)

| Sınıf | Komutlar | Zorlama |
| :--- | :--- | :--- |
| **A — Yönlendirme (10)** | `test→run_tests`, `sh→run_command`, `read→read_file`*, `write→write_file`*, `apply→apply_buffer`, `symbols→search_symbols`, `outline→get_outline`, `refs→find_references`, `ast→get_symbol`, `diagnostics→lsp_diagnostics` *(YENİ)* | REDIRECT_MAP steering (* savunmacı) |
| **B — Ajan-görünür (17)** | `diff`, `status`, `undo`, `rollback`, `autoapply`, `context`, `steps`, `config`, `model`, `providers`, `runtime`, `fibers`, `services`, `agents`, `lint`, `format`, `history` | `audience: :both`; prompt'ta `<agent_commands>` |
| **C — Oturum kontrolü (4)** | `quit`, `exit`, `clear`, `reset` | Sert blok + steering *(YENİ)* |
| **D — Reentrancy (2)** | `plan`, `goal` | Blok + "finish kullan" yönlendirmesi *(mesaj yenilenir)* |
| **E — Yetki/kabiliyet (5)** | `provider`, `workspace`, `roots`, `allow`, `allow-dir` | `:human` steering *(YENİ)* |
| **F — UI/meta (7)** | `verbosity`, `verbose`, `help`, `commands`, `lsp`, `replay`, `session` | `:human` steering *(YENİ)* |

---

## 🔄 5. Uygulama Aşamaları

### A — Kontrat Çekirdeği (`shell.rb`)
1. `register_command` imzasına `audience: nil` eklenir; doğrulama + meta saklama (D-1).
2. `Shell#agent_commands` yardımcısı: `audience != :human` olan kayıtların sıralı `[ad, meta]` listesi (prompt üretimi ve testlerin ortak kaynağı).
3. `shell.rb` satır bütçesi korunur (< 600; testle sabit) — ek ~4 satır.

### B — Kayıt Turları ve Zorlama
1. `commands/*.rb` içinde D-2'deki 17 kayda `audience: :both` eklenir (geri kalan ~28 siteye dokunulmaz; varsayılan `:human`).
2. `ExecReplCommandTool` (D-3 sırası): `SESSION_CONTROL` sabiti + mesajlar; `plan/goal` mesajına *"You are already running inside the agent loop. Continue the current task; call the 'finish' tool when the goal is complete."*; `:human` kitle steering'i (*"'!x' is reserved for the human operator."* + kategori ipucu); `REDIRECT_MAP += diagnostics` (D-4); açıklama metni yeniden yazım (D-5).

### C — Prompt Katmanı (`context_builder.rb`)
1. `build_commands_xml` → `<agent_commands>` üretimi (built-in, `audience != :human`; custom hariç) + `<custom_commands>` aynen.
2. `build_operational_rules_xml(shell = nil)`: kural 4 listesi metaveriden üretilir; kural 1 tonu (D-6). `build_system_prompt` zaten `shell` aldığından çağrı zinciri basittir.

### D — History Sızıntısı, Testler ve Dokümantasyon
1. `agent.rb:200` tek satır (D-8).
2. Yeni test: `test/unit/test_agent_command_contract.rb` — erişim matrisinin tamamı (B sınıfı 17'si çalışır; C sert blok; D mesajı `finish` içerir; E/F `:human` steering; A `diagnostics` yönlendirmesi; `audience` varsayılanları; `custom ⇒ :both`; `Shell#agent_commands` doğruluğu).
3. Güncellenen testler: `test_repl_tool_separation_and_guardrails.rb` (prompt artık `<agent_commands>` **içerir** ve insan-only komutları **içermez**; kural 4 substring'i yeni metne; `!test` redirect testleri aynen), goal/history testi (`"Goal:"` var / literal `"!goal"` yok / kayıtçı ham komut var), `<agent_commands>` ≤ 250 token eşiği.
4. `README.md` ajan aracı bölümüne kısa kontrat özeti (tek paragraf).

---

## 🧪 6. Test Planı

| Test | Doğrulama |
| :--- | :--- |
| Erişim matrisi (yeni dosya) | §4.1 tablosunun 6 sınıfı tek tek; `audience` doğrulama/varsayılanları |
| Prompt görünürlüğü | `<agent_commands>` kümesi == `Shell#agent_commands`; `!quit`/`!plan`/`!allow`/`!provider` prompt'a sızmaz |
| Tek kaynak | `ExecReplCommandTool` açıklaması statik komut listesi içermez; iki farklı kabukla üretilen kurallar farklı listeler üretir |
| Oturum güvenliği | `exec_repl_command("!quit")` kabuğu durdurmaz; `!clear`/`!reset` geçmişi silmez (mesaj döner) |
| History sızıntısı | Goal sonrası `conversation_history` `"Goal:"` içerir, `"!goal"` içermez; `recorder` ham `"!goal …"` alır |
| Token bütçesi | `TokenEstimator` ile `<agent_commands>` ≤ 250 |
| Regresyon | Mevcut paketin tamamı (hedef: 647+ koşu, 0 hata); rubocop yeni ihlâlsiz; `shell.rb` < 600 satır |

---

## ✅ 7. Kabul Kriterleri

1. Tam test paketi yeşil; rubocop yeni ihlâlsiz; `shell.rb` < 600 satır.
2. Erişim matrisi testi tam geçer (A:10, B:17, C:4, D:2, E:5, F:7).
3. Sistem prompt'unda `<agent_commands>` tam küme mevcut; insan-only komut sızmaz; bölüm ≤ 250 tahmini token.
4. Statik komut listesi çift kopyası kalmaz (kural 4 + araç açıklaması üretimlidir).
5. `conversation_history` literal `"!goal"`/`"!plan"` içermez; oturum kayıtçısı ham komutu korur.
6. Model `!quit`/`!clear`/`!reset`/`!exit` çağıramaz; `!plan`/`!goal` bloğu yönlendirme içerir; `!diagnostics` `lsp_diagnostics`'a yönlenebilir.
7. Manuel smoke (opsiyonel): goal modunda `exec_repl_command("!diff")` kirli buffer değişikliklerini listeler.

---

## ⚠️ 8. Riskler

| Risk | Azaltım |
| :--- | :--- |
| Prompt değişikliğinin model davranışında kayma yaratması | Yönlendirme mesajlarının anlamı korunur; kritik substring'ler testle sabitlenir; `!test` vb. redirect semantiği değişmez |
| `shell.rb` satır bütçesi | Ek ~4 satır; taşarsa `agent_commands` sorgusu `commands.rb` modülüne |
| Ajanın goal sırasında kendi değişikliğini `!undo` ile geri alması | Bilinçli kabul (D-10, §1.A); `auto_apply` etkileşimi README'de |
| `!model` geçişinin mevcut run'a etki etmemesi | Dokümantasyon (D-10); davranış değişikliği yok |
| Custom komut yazarlarının bozulması | `custom ⇒ :both` geriye dönük uyumlu; `synthesize_command` akışı testlenir |

---

## 📝 9. Sapmalar

- **D-5 / D-7 (rafine):** Kural 4, üretilen komut adlarını içermez; `<agent_commands>` bölümüne atıf yapar. `<agent_commands>` etiket-başına-description formatı yerine **sade ad listesi**dir (17 ad ≈ 70 tahmini token; kural 4 ile birlikte toplam ≪ 250 bütçesi). Gerekçe: etiketli format TokenEstimator ile 380+ token tutuyordu; ad listesi tek kaynağı korur ve token disiplinine uyar.
- **D-8 (genişletildi):** Teşhis S-3'teki "tek sızıntı noktası agent.rb:200" tespiti **eksikti**. İki sızıntı kaynağı daha bulundu ve kapatıldı: (1) `shell.rb execute_command`, takip edilen her komutun ham `!cmd` satırını conversation_history'ye yazıyordu → kaynakta bang strip'i; (2) `session/manager.rb restore_session`, resume sırasında kayıtlı ham komutları ve `!goal …` user_turn'ü birebir history'ye geri enjekte ediyordu (kod incelemesi ajanı tarafından yakalandı) → hidrasyonda bang strip'i + `Goal:` normalizasyonu. Oturum dosyası ham komutları korur; Replayer bütünlüğü bozulmaz.
- **D-3 (sıkılaştırma):** plan/goal kapısı ham string prefix eşleşmesinden (`cmd.start_with?("!plan")`) normalize `base_cmd` eşleşmesine (`["plan", "goal"].include?(base_cmd)`) çevrildi; aksi halde `plan_cache` gibi `:both` özel komutları hatalı bloklanıp `!PLAN` bypass üretiyordu. Zorlamadaki `:human` denetimi denylist'ten fail-closed allowlist'e (`[:agent, :both]`) çevrildi — gelecekteki yeni audience değeri her iki tarafta da kapıda kalır.
- **§5-A.2 (sapma):** `Shell#agent_commands` yardımcısı eklenmedi (shell.rb 600 satır bütçesi); tek filtre kaynağı `ContextBuilder.build_agent_commands_xml`'dir (REPL↔Prompt dairesel require'dan da kaçınır). Zorlama tarafı `meta[:audience]` okuması meta Veri erişimidir, filtre kopyası değildir.
- **`include_builtins:` kaldırıldı:** `build_commands_xml`'in Plan 36'dan beri çağrılmayan `include_builtins:` parametresi ve `<repl_commands>` üretimi silindi (tek test çağırıcısı güncellendi).
- **Karmaşıklık/satır bütçesi:** `build_commands_xml` Rubocop CyclomaticComplexity sınırına takıldı → `build_agent_commands_xml` / `build_custom_commands_xml` yardımcılarına bölündü. shell.rb fetch-tabanlı audience doğrulamasıyla 598 satırda tutuldu.
- **Çevresel arızalar (önceden var, kanıtlandı):** tam pakette reline 0.6.3 `reset` arity ArgumentError (1) ve Windows temp-dir EACCES teardown hataları (2) HEAD'de de birebir üretildi; Plan 53 kaynaklı değildir.
