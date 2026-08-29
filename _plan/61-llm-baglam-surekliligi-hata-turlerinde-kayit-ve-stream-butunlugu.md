# 61 — LLM Bağlam Sürekliliği: Hata Turlarında Context Kaydı, Model Geçiş Tutarlılığı ve Stream/Assembly Bütünlüğü

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes
> **Durum:** ✅ **Tamamlandı (29 Ağustos 2026)** · **Zorluk:** Orta–Zor · **Faz:** 6 (Sistem Dayanıklılığı & Bağlam Sürekliliği)
> **İlgili Planlar:** [17](17-yerel-arac-cagrilari-ve-router.md), [30](30-dinamik-llm-saglayicilari-ozel-endpointler-ve-baglam-limiti.md), [31](31-agentic-adim-butcesi-ve-dinamik-genisletme.md), [32](32-agentic-tool-cagrilari-yapilandirilmis-io-ve-akilli-baglam-kirpma.md), [34](34-spatiotemporal-oturum-kaliciligi-ve-aninda-hafiza-yukleme.md), [35](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md), [42](42-orchestrator-loop-dekompozisyonu-ve-llm-formatlayici.md), [50](50-varsayilan-llm-stream-iletisimi-ve-canli-token-akisi.md), [54](54-step-executor-ve-arac-alani-moduler-refaktoru.md), [57](57-sistem-saglamligi-birlesik-tanilama-fuzyonu-e2e-ve-thread-safety.md)
> **Kapsam:** `lib/rubik/llm/ollama.rb`, `lib/rubik/llm/anthropic.rb`, `lib/rubik/llm/openai_compatible.rb`, `lib/rubik/llm/registry.rb`, `lib/rubik/llm/router.rb`, `lib/rubik/llm/formatter.rb`, `lib/rubik/llm/provider.rb`, `lib/rubik/orchestrator/loop.rb`, `lib/rubik/orchestrator/stream_manager.rb`, `lib/rubik/orchestrator/budget_manager.rb`, `lib/rubik/prompt/context_compactor.rb`, `lib/rubik/repl/shell.rb`, `lib/rubik/session/manager.rb`, `lib/rubik/repl/commands/agent_context.rb`, `test/unit/` (yeni testler)

---

## 🎯 1. Problem ve İhtiyaç Analizi

**Kullanıcı şikayeti:** *"LLM context'i hatırlamıyor. Bir hata ile karşılaşıldığında context yazılmıyor/güncellenmiyor olabilir. Default/fast/advanced LLM set edilmesi ve geçişleri context'i bozuyor olabilir."*

Chat stream → context assembly → kalıcılık zincirinin uçtan uca denetiminde **14 doğrulanmış bulgu** tespit edildi. Şikayetin iki hipotezi de doğrulandı; ayrıca ikisinden bağımsız olarak davranışı tek başına açıklayabilecek **iki kritik kök neden** (B1, B2) bulundu.

### 🔴 Kritik Kök Nedenler (P0)

#### B1 — Ollama `num_ctx` hiç gönderilmiyor: sunucu tarafı sessiz prompt kesimi
- **Kanıt:** [`lib/rubik/llm/ollama.rb:20-96`](../lib/rubik/llm/ollama.rb) — `complete` ve `stream_chat` payload'larında `options: { num_ctx: ... }` alanı yok.
- **Mekanizma:** Registry, Ollama için `context_limit = 32_768` varsayar ([registry.rb:20](../lib/rubik/llm/registry.rb)); compactor buna göre 20k+ token'lık prompt gönderir. Ancak Ollama sunucusu istek başına varsayılan bağlam penceresiyle (~2k–4k token, sürüm/model bağlı) çalışır ve prompt'un **başından keser**: sistem promptu, AGENTS.md protokolü ve eski konuşma turları model hiç görmeden kaybolur. API hatası döndürülmez; model "hiçbir şey hatırlamıyor" görünür.
- **Varsayılan konfigürasyon Ollama olduğu için** ([config.rb:13-34](../lib/rubik/config.rb)) bu, şikayetin en olası tek başına açıklamasıdır.

#### B2 — Hata/iptal/başarısız turlar conversation history'ye hiç yazılmıyor
- **Kanıt:** [`lib/rubik/repl/shell.rb:444-477`](../lib/rubik/repl/shell.rb) — `execute_free_text` içinde `@conversation_history` güncellemesi **yalnızca `res[:ok] == true` iken** yapılır.
- **Kapsam:**
  - `rescue Rubik::LLM::ClientError` / `rescue StandardError` (ağ hatası, 4xx/5xx, JSON parse): tur tamamen düşer; **kullanıcı mesajı dahil** hiçbir şey history'ye eklenmez.
  - `rescue Interrupt` (Ctrl+C): `cancelled_turn` yalnızca session recorder'a yazılır; conversation history'ye değil.
  - `res[:ok] == false` (max steps aşıldı + devam edilmedi, "Repeated invalid tool call"): yine hiçbir şey yazılmaz.
- **Sonuç:** Model 15 araç adımı boyunca dosya okuyup tampona yazmış olsa bile tur hata ile biterse, bir sonraki turda o çalışmanın **iz bile** kalmaz. Recorder'a da `assistant_response` yazılmadığı için `!resume` ile de geri gelmez — kayıp kalıcıdır. Kullanıcı hipotezi #1 birebir doğrulandı.

### 🟠 Yüksek Öncelik (P1)

#### B3 — Anthropic `max_tokens` 1024'te sabit: yanıtlar sessizce kesiliyor
- **Kanıt:** [`lib/rubik/llm/anthropic.rb:39,104`](../lib/rubik/llm/anthropic.rb) — `payload[:max_tokens] = opts[:max_tokens] || 1024`. Loop isteğe `max_tokens` iletmez ([loop.rb:59-61,136](../lib/rubik/orchestrator/loop.rb)); `max_output_tokens` yalnızca compaction matematiğinde kullanılır, request'e geçmez. Registry'deki `DEFAULT_MAX_OUTPUT_TOKENS["anthropic"] = 8_192` değeri ([registry.rb:24-31](../lib/rubik/llm/registry.rb)) provider'a hiç ulaşmaz.
- **Sonuç:** Claude yanıtları 1024 token'da kesilir; uzun planlar/finish mesajları yarım kalır, tool-call JSON'u yarışta kopabilir.

#### B4 — Ollama streaming modunda native tool_calls tamamen yok sayılıyor
- **Kanıt:** [`lib/rubik/llm/formatter.rb:350-372`](../lib/rubik/llm/formatter.rb) — `OllamaFormatter#parse_stream_event` yalnızca `response` (text) ve `done/usage` işler; NDJSON satırındaki `message.tool_calls` alanını chunk'a hiç taşımaz. `StreamManager#build_response_from_chunks` bu yüzden tool_calls'u sıfır toplar.
- **Sonuç:** Model native tool call yaptığında çağrı kaybolur (metin içi ```json bloğu yazmadıkça). Model "yaptım" der, sistem çalıştırmaz; geçersiz-döngü/şüpheli davranış üretilir. `BaseProvider#complete` fallback'i de stream chunk'larından tool_calls toplamadığı için ([provider.rb:92-110](../lib/rubik/llm/provider.rb), `tool_calls: []`) stream-only özel sağlayıcılarda tool calling baştan kırıktır.

#### B5 — Custom sağlayıcı `context_limit`'i spec'ten okunmuyor
- **Kanıt:** [`lib/rubik/llm/registry.rb:60-124,171-184`](../lib/rubik/llm/registry.rb) — `register_provider_spec`, provider seviyesindeki `context_limit` alanını `OpenAICompatibleProvider` kurucusuna iletmez; `context_limit_for` custom provider'da model kataloğu eşleşmesi yoksa kurucu default'u olan 32_768'e düşer.
- **Sonuç:** 128k/200k'lık model 32k sanılır → gereksiz agresif compaction → "hata yok ama model eski konuşmayı unuttu" durumu. (`!model set ...` ile rol atanırken aynı şekilde yanlış limit hesaplanır.)

#### B6 — Oturum geri yüklemede asılı `user` mesajları ve ardışık rol ihlali
- **Kanıt:** [`lib/rubik/session/manager.rb:75-138`](../lib/rubik/session/manager.rb) — `restore_session`, `user_turn` olaylarını koşulsuz turn'e çevirir; hatalı/iptal turlar (B2 nedeniyle assistant_response'suz kalanlar) **ardışık `user` mesajları** veya sonda asılı `user` üretir. `AnthropicFormatter` ardışık aynı-rollü mesajları birleştirmez ([formatter.rb:184-224](../lib/rubik/llm/formatter.rb)).
- **Sonuç:** Resume sonrası Anthropic uç noktalarında 400 ("roles must alternate") riski + canlı oturumda var olmayan kirlenmiş bağlam. OpenAI uyumlu uçlar sessizce tolere eder; Anthropic'te ise hata → B2 ile birleşerek tam tur kaybı.

### 🟡 Orta Öncelik (P2)

#### B7 — Her serbest metin turunda yeniden routing: model kimliği durmadan değişiyor
- **Kanıt:** [`lib/rubik/repl/shell.rb:400`](../lib/rubik/repl/shell.rb) (`@router.route(task_type: :auto, prompt: text)`) + [`lib/rubik/llm/router.rb:76-83`](../lib/rubik/llm/router.rb) (`classify_prompt` anahtar kelime taraması).
- **Mekanizma:** `router.mode = "auto"` (varsayılan) iken "hızlı bir kontrol et" → fast rolü (ör. 1.5b model), "refactor planla" → advanced. Konuşma içinde model durmadan değişir; kullanıcı `!model set advanced X` dese bile fast/advanced rolleri keyword'e göre yine devreye girer. Kullanıcı hipotezi #2'nin ana mekanizması: küçük fast model önceki turların bağlamını zayıf işler, stil/kişilik sıçrar, `context_limit` turdan tura değiştiği için compaction eşiği oynar.

#### B8 — `!` komut çıktıları conversation history'ye limitsiz giriyor
- **Kanıt:** [`lib/rubik/repl/shell.rb:343-348`](../lib/rubik/repl/shell.rb) — TeeIO yakalanan çıktı ANSI temizlidir ama **boyut sınırı yoktur**; `!sh`/`!plan` gibi büyük çıktılar ham halde assistant mesajı olur.
- **Sonuç:** Tek bir komut çıktısı bağlamın büyük kısmını işgal eder; B12 ile birleşince compaction indiremez (tek mesaj bölünemez) → emergency → tur kaybı zinciri.

#### B9 — Sliding window indirgenemeyen dev mesajları bırakır; summary mesajı konum/rol tuhaflığı yaratır
- **Kanıt:** [`lib/rubik/prompt/context_compactor.rb:141-192`](../lib/rubik/prompt/context_compactor.rb) — `apply_sliding_window` yalnızca atomik unit'ları düşürür; tek bir mesaj eşiği aşıyorsa user mesajı **hiç kırpılmaz** (EmergencyCompactor yalnız tool/assistant kırpıyor, [emergency_compactor.rb:19-41](../lib/rubik/prompt/emergency_compactor.rb)). `summary_message` ortada `role: "system"` ekler: OpenAI tarafı bunu `[System Notification]` user'ına çevirir (iyi), Anthropic tarafı ise **tüm system mesajlarını toplayıp en baştaki top-level system'e taşır** ([anthropic.rb:31-34,97-99](../lib/rubik/llm/anthropic.rb)) — sıra bilgisini kaybolur.
- **Ek hata:** döngüde `candidate` shift'ten önce hesaplandığı için son düşürme sonrası eşik tekrar ölçülmez ([context_compactor.rb:171-178](../lib/rubik/prompt/context_compactor.rb)).

#### B10 — Yarım/bozuk tool argümanları sessizce `{}` oluyor
- **Kanıt:** [`lib/rubik/orchestrator/stream_manager.rb:114-133`](../lib/rubik/orchestrator/stream_manager.rb) — `args_json` parse edilemezse `rescue` içinde sessizce `{}` döner; ne kullanıcıya ne de modele tanılama girer. Araç "eksik argüman" hatası verir, model kendini yanlış suçlar.

#### B11 — Boş LLM yanıtı turu sessizce bitiriyor
- **Kanıt:** [`lib/rubik/orchestrator/loop.rb:231-235`](../lib/rubik/orchestrator/loop.rb) — `tool_calls` boş + `text_resp` boş ise history'ye **hiçbir şey eklenmeden** `{ok: true, output: ""}` döner; shell de boş string'i assistant mesajı olarak history'ye yazar. (Boş content string ayrıca bazı API'lerde reddedilir.)

#### B12 — Konuşma penceresi adet bazlı (`last(20)`), token bazlı değil
- **Kanıt:** [`lib/rubik/repl/shell.rb:460-461`](../lib/rubik/repl/shell.rb), [`lib/rubik/session/manager.rb:137`](../lib/rubik/session/manager.rb), [`lib/rubik/repl/commands/agent_execution.rb:103`](../lib/rubik/repl/commands/agent_execution.rb) — 20 entry ≈ 10 değişim; komut çiftleri de 2'şer entry harcar. Kalıcı hafıza hem kısa hem öngörülemez (B8 ile birleşir).

#### B13 — `!context compact` hedef modeli yanlış hesaplıyor
- **Kanıt:** [`lib/rubik/repl/commands/agent_context.rb:54-70`](../lib/rubik/repl/commands/agent_context.rb) — sıkıştırma daima **default** rolün limitine göre yapılır; bir sonraki turda route edilecek modelin (ör. fast, 8k) limitine göre değil.

#### B14 — `continue_loop`/step-budget XML'i son mesajın içine enjekte oluyor
- **Kanıt:** [`lib/rubik/orchestrator/loop.rb:114-119`](../lib/rubik/orchestrator/loop.rb), [`lib/rubik/orchestrator/budget_manager.rb:24-27`](../lib/rubik/orchestrator/budget_manager.rb) — `@history.last[:content]` bir `tool` mesajı veya `content: nil` assistant mesajı olabilir; string birleştirme provider dönüşümünde rol uyumsuzluğu üretir.

---

## 🧩 2. Tasarım Kararları (Design Decisions)

### D-1 (B1): Ollama `num_ctx` gönderimi — `OllamaProvider`
`complete` ve `stream_chat` payload'larına:
```ruby
num_ctx = opts[:num_ctx] || opts[:context_limit]
payload[:options] = { num_ctx: num_ctx.to_i } if num_ctx && num_ctx.to_i.positive?
```
- `Loop#send_llm_request_with_recovery` isteğe `context_limit: @context_limit` ekler; böylece compactor'ın hedeflediği pencere ile sunucunun fiilen kullandığı pencere **aynı kaynaktan** beslenir.
- Yanıtın `prompt_eval_count` değeri gerçek giriş token'ını verir; ilk turda `prompt_eval_count > num_ctx × 0.9` ise `on_step(type: :context_truncation_warning)` olayı yayınlanır (görünür teşhis).
- **Yeni config:** `providers.<name>.num_ctx` (opsiyonel override) — registry provider spec'ini provider kurucusuna taşır (D-5 ile aynı kanal).

### D-2 (B2): Hata turlarında da bağlam kalıcılığı — `execute_free_text` yeniden yazımı
Tur sonuçlandırması tek bir `finalize_turn!` metoduna taşınır ve **her durumda** çalışır (`ensure` benzeri):
1. **Başarı:** mevcut davranış (user + assistant çifti).
2. **`res[:ok] == false` (max steps / invalid tool):** user mesajı + `"[Turn incomplete: <error summary>. Work performed up to this point is summarized below.]"` önekiyle assistant tur-özeti eklenir. Tur özeti loop instance'ından üretilir: çalışan araç adımları + kirli tampon dosya listesi (bkz. D-15).
3. **Exception (ClientError/StandardError):** user mesajı + `"[Turn failed: <error>. No response was produced.]"` içerikli assistant mesajı. Model bir sonraki turda neyin başarısız olduğunu **bilir** ve kullanıcı sorduğunda hatayı hatırlar.
4. **Interrupt:** user mesajı + `"[Turn cancelled by user (^C). Partial progress: ...]"` assistant mesajı (recorder'daki `cancelled_turn` kaydı aynen kalır).
- Eklenen assistant mesajları `Rubik::Session::Recorder#record_assistant_response` ile de kayda geçer → `!resume` tutarlı kalır.
- Hata mesajı metinleri `[Turn ...]` önekiyle damgalanır; restore ve compaction katmanları bu öneki tanır (D-6).

### D-3 (B3): `max_output_tokens`'ın request'e taşınması
`Loop` isteğe `max_tokens: @max_output_tokens` ekler (yalnızca pozitifse). Anthropic default'u `1024` → `DEFAULT_MAX_OUTPUT_TOKENS` ile uyumlu davranışa kavuşur. OpenAI-uyumlu/Ollama tarafı mevcut `if opts.key?` guard'larıyla zaten güvenlidir.

### D-4 (B4): Ollama streaming tool_calls + `complete` fallback bütünlüğü
- `OllamaFormatter#parse_stream_event`: NDJSON satırında `message.tool_calls` varsa `tool_use_delta` olarak normalize edilir (`index/id/name/args` şeklinde; `build_response_from_chunks` zaten `args` dalını destekliyor).
- `BaseProvider#complete` fallback'i: chunk'lardaki `tool_use_delta`'ları mevcut birleştirme mantığıyla (`index` bazlı, `args_json` biriktirme) toplayıp `Response#tool_calls`'a koyar; `StreamManager#build_response_from_chunks` bu amaçla `StreamManager`'dan çıkarılıp `Rubik::LLM::ChunkAssembler` olarak yeniden kullanılabilir hale getirilir (tek kaynak, iki tüketici).

### D-5 (B5): Provider spec'inden limit taşınması
`register_provider_spec`, `p_spec["context_limit"]` / `p_spec["max_output_tokens"]` alanlarını `OpenAICompatibleProvider.new(default_context_limit: ..., max_output_tokens: ...)` üzerinden taşır; `context_limit_for` / `max_output_tokens_for` lookup sırası: **model kataloğu → provider default'u → sağlayıcı sınıfı tablosu**. `!model add ... --context=` akışı (agent_models.rb) değişmez, artık gerçekten etkili olur.

### D-6 (B6): Geçmiş onarımı — rol normalizasyonu katmanı
Yeni saf fonksiyon: `Rubik::LLM::MessageSanitizer.normalize(messages)`:
- Ardışık aynı-rollü mesajları tek mesajda birleştirir (`\n\n` ile; assistant+tool_calls bloklarını koruyarak).
- Sonda asılı `user` (yanıtsız son tur) kalırsa B2'nin `[Turn ...]` damgası yoksa `"[No assistant response was recorded for this turn.]"` tamamlayıcısı eklenir.
- `AnthropicProvider` ve `OpenAICompatibleProvider` `format_messages` öncesi sanitize eder (formatter'a enjeksiyon yerine provider seviyesinde — tek yerden). `restore_session` da hydrate sonrası aynı fonksiyonu çağırır; `turns.last(20)` penceresi D-12 ile değişir.

### D-7 (B7): Yapışkan routing (sticky routing) — konuşma boyunca model tutarlılığı
`router.mode = "auto"` için yeni alt mod: `router.sticky` (varsayılan `true`):
- Serbest metin turlarında routing yalnızca **konuşma başlamamışsa** (conversation_history boşsa) veya açık `task_type` verilmişse sınıflandırma yapar; aksi halde aynı konuşmanın önceki turunun rolünü/provider'ını tekrar kullanır.
- Shell, `@conversation_last_route = { role:, provider:, model: }` tutar; `!model` ile geçiş yapıldığında damga güncellenir ve yeni model konuşmanın kalanı için sabitlenir.
- `router.sticky = false` (`!config set router.sticky false`) ile eski davranışa dönüş mümkün. Plan/Goal gibi açık `task_type`'lı çağrılar damgayı **değiştirmez** (yalnızca serbest metin damgasıdır).

### D-8 (B8): Komut çıktısının history'ye sınırlı girişi
`execute_command` içinde captured çıktı `Rubik::Tools::Truncator.truncate(output_text, max_chars: tools.max_output_chars, strategy: :head_tail)` süzgecinden geçirilir (varsayılan 12_000 karakter); kesilme olduysa `"\n[output truncated, N chars total — run the command again to see full output]"` dipnotu eklenir. Recorder tam metni tutmaya devam eder (`record_repl_command` öncesi kesilmez) — LLM bağlamı ile oturum kaydı ayrışır.

### D-9 (B9): Compactor sertleştirmesi
- `apply_sliding_window`: döngü her düşürme sonrası yeniden ölçer; eşik hâlâ aşılıyorsa kalan en büyük `user`/`assistant` mesajları da `max_chars` ile kırpılır (tool mesajları mevcut `prune_intermediate_tool_results` yolundan).
- `summary_message` rolü `system` → **`user`** yapılır ve içeriği `<context_compaction count="N" note="..." />` biçimine taşınır; böylece Anthropic tarafında başa taşınma tuhaflığı ortadan kalkar, OpenAI tarafındaki `[System Notification]` çevirisi gerekmez (geriye dönük olarak iki formatter da bu yeni rolü doğal işler).

### D-10 (B10): Bozuk tool args tanılamaması
`ChunkAssembler` içinde parse hatasında: args `{}` bırakılır ama mesaj geçmişine `role: "tool"` sonucu olarak `⚠️ Tool arguments could not be parsed (stream truncated?). Raw JSON fragment: <ilk 200 char>` eklenir ve `on_step(type: :malformed_tool_args, tool: name)` yayınlanır. Model hatayı görür, kendini düzeltir.

### D-11 (B11): Boş yanıt turu
`process_step_response`: `tool_calls.empty? && text_resp.empty?` ise tur bitirmek yerine history'ye `role: "user"` denetim notu: `"Your last response was empty. Continue the task or call finish."` eklenip döngü devam eder; art arda 2 boş yanışta mevcut davranışa güvenli dönüş (`{ok: false, error: "Empty response from model"}`). Shell tarafı artık asla boş content'li assistant mesajı eklemez.

### D-12 (B12): Token-farkındal kalıcı pencere
`conversation_history` için `last(20)` yerine `Rubik::Prompt::ContextCompactor.trim_history_to_budget(history, ceiling:)` — en eski çiftler teneken (token) bütçesine sığana kadar atılır, en az 2 çift korunur. `execute_free_text`, `execute_command`, `!goal` ve `restore_session` aynı fonksiyonu çağırır. Ceiling, o anki hedef modelin (`@conversation_last_route` veya default rol) `effective_input_limit_for` değeridir.

### D-13 (B13): `!context compact` hedef modeli
Sıkıştırma, D-7'deki `@conversation_last_route` varsa onun limitine göre; yoksa default rol ile yapılır. Çıktı hangi modele göre sıkıştırıldığını yazar.

### D-14 (B14): Enjeksiyon güvenliği
`continue_loop` ve `evaluate_step_budget_warning!` XML'i `@history.last`'a değil, daima **yeni bir `role: "user"` mesajı** olarak ekler (`<system_notification .../>` içerikli). Son mesajın tipinden bağımsız olarak provider dönüşümü güvenli kalır.

### D-15 (tur özeti altyapısı — D-2/3/4'ün beslediği)
`Orchestrator::Loop` tur boyunca düşük maliyetli bir aktivite günlüğü tutar: çağrılan araç adları (frekans), yazılan/okunan dosya yolları (ilk N), hata alan araçlar. `Loop#turn_summary` metodu bunu 3-6 satırlık kompakt bir örnece dönüştürür; yalnızca başarısız/iptal turlarında (D-2) ve isteğe bağlı `agent.summarize_turns = true` iken başarılı turlarda da assistant mesajının sonuna `<turn_summary>` bloğu olarak eklenir.

---

## 🛠 3. Uygulama Adımları (Dosya Bazında)

| # | Dosya | Değişiklik | Karar |
| :-- | :--- | :--- | :-- |
| 1 | `lib/rubik/llm/ollama.rb` | `options.num_ctx` gönderimi + truncation uyarısı | D-1 |
| 2 | `lib/rubik/orchestrator/loop.rb` | isteğe `context_limit` & `max_tokens` eklenmesi; boş yanıt işleyişi; notification mesajları; aktivite günlüğü + `turn_summary` | D-1, D-3, D-11, D-14, D-15 |
| 3 | `lib/rubik/repl/shell.rb` | `finalize_turn!` (her durumda history+recorder yazımı); sticky route damgası; token-bütçeli pencere; komut çıktısı truncation'ı | D-2, D-7, D-8, D-12 |
| 4 | `lib/rubik/llm/formatter.rb` | Ollama `message.tool_calls` normalize; (summary rolü değişikliği sonrası formatter basitleşmesi) | D-4, D-9 |
| 5 | `lib/rubik/llm/provider.rb` + `lib/rubik/orchestrator/stream_manager.rb` | `ChunkAssembler` çıkarımı; `complete` fallback'te tool_calls toplanması; bozuk args tanılaması | D-4, D-10 |
| 6 | `lib/rubik/llm/registry.rb` | provider spec'inden `context_limit`/`max_output_tokens`/`num_ctx` taşınması | D-1, D-5 |
| 7 | `lib/rubik/llm/message_sanitizer.rb` (yeni) | ardışık rol birleştirme + asılı user tamamlama; provider'lara ve `restore_session`'a bağlanması | D-6 |
| 8 | `lib/rubik/llm/router.rb` + `lib/rubik/config.rb` | `router.sticky` (default `true`) | D-7 |
| 9 | `lib/rubik/prompt/context_compactor.rb` | sliding-window yeniden ölçüm + mesaj içi kırpma + summary rol/içerik değişimi + `trim_history_to_budget` | D-9, D-12 |
| 10 | `lib/rubik/session/manager.rb` | restore sonrası sanitize + token-bütçeli pencere | D-6, D-12 |
| 11 | `lib/rubik/repl/commands/agent_context.rb` | `!context compact/stats` hedef model düzeltmesi | D-13 |
| 12 | `lib/rubik/orchestrator/budget_manager.rb` | step-budget XML'i ayrı user mesajı olarak | D-14 |
| 13 | `COMMANDS.md` / `CONFIG.md` / `README.md` | `router.sticky`, `providers.*.num_ctx`, `[Turn ...]` damgaları, `!context` davranış değişikliği dokümantasyonu | — |

**Uygulama sırası:** 1→2→3 (P0 zinciri: kök neden + hata turları) ⇒ 4→5→6→7 (P1) ⇒ 8→14 küçük düzeltmeler ⇒ 9→12 (P2 pencere/compactor) ⇒ dokümantasyon. Her aşama sonunda tam test paketi çalışır.

---

## 🧪 4. Test Planı

**Yeni test dosyaları:**
- `test/unit/test_ollama_num_ctx.rb` — D-1: payload'da `options.num_ctx` varlığı; `prompt_eval_count` aşımında uyarı olayı; override öncelik sırası.
- `test/unit/test_failed_turn_persistence.rb` — D-2: ClientError sonrası history'de user+`[Turn failed...]` çifti; Interrupt sonrası `[Turn cancelled...]`; max-steps reddi sonrası özetli tur; recorder'a `assistant_response` yazıldığının doğrulanması.
- `test/unit/test_chunk_assembler.rb` — D-4/D-10: Ollama NDJSON tool_calls'un `Response#tool_calls`'a ulaşması; yarım `args_json`'da tanılama mesajı; `BaseProvider#complete` fallback'te tool_calls korunumu.
- `test/unit/test_message_sanitizer.rb` — D-6: ardışık user birleştirme; asılı user tamamlama; assistant+tool_calls bloklarının bozulmaması.
- `test/unit/test_sticky_routing.rb` — D-7: ikinci turda model değişmemesi; `!model` sonrası damga güncellenmesi; `sticky=false` davranışı.
- `test/unit/test_turn_window_budget.rb` — D-12: token bütçesi aşımında en eski çiftin atılması; min 2 çift koruması; restore penceresi.

**Güncellenen mevcut testler:** `test_conversation_history.rb` (hata turları), `test_context_compactor_and_truncation.rb` (D-9), `test_session_persistence_and_resume.rb` (D-6), `test_orchestrator_stream.rb` (D-4), `test_native_tool_calling_and_router.rb` (D-7), `test_loop_decomposition.rb` (D-3/D-14).

**El ile doğrulama (Ollama):** uzun bir konuşmada 5+ tur sonrası modelin ilk turdaki dosya adını hatırlaması; `!context stats` gösterimi ile `prompt_eval_count`'un uyumu.

---

## ⚠️ 5. Riskler ve Geriye Dönük Uyumluluk

| Risk | Azaltım |
| :--- | :--- |
| `num_ctx` yükseltmesi yerel VRAM kullanımını artırır (küçük GPU'larda OOM) | `providers.<name>.num_ctx` override; varsayılan değer `context_limit` ile sınırlı; Ollama OOM hatası mevcut auto-recover akışına düşer |
| Hata turlarının history'ye yazılması bağlamı büyütür | `[Turn ...]` mesajları kısa ve damgalı; D-12 penceresi bütçeyi korur; `context.log_failed_turns = false` ile kapatılabilir |
| Sticky routing, kullanıcıların auto-classification alışkanlığını değiştirir | Varsayılan `true` ama tek config ile kapatılabilir; `!model route` mevcut manual mod aynen durur |
| Summary rolünün `user`'a dönüştürülmesi eski oturum dosyalarını etkiler mi? | Etkilemez — compactor çalışma anında üretir; sanitize katmanı eski `system` summary'leri de doğru işler |
| Anthropic `max_tokens` 8192'ye çıkması maliyeti artırır | Değer config'ten (`providers.anthropic.max_output_tokens`) ezilebilir |

---

## ✅ 6. Kabul Kriterleri

1. **Ollama'da 5 turluk bir konuşmada model 1. turdaki spesifik detayı (dosya adı/satır) hatırlar** ve gönderilen `prompt_eval_count` ≤ hedef `num_ctx` kalır.
2. Ağ hatası/4xx/Ctrl+C/max-staps ile biten bir turdan sonra `!context stats` history'de `[Turn ...]` damgalı kaydı gösterir; sonraki turda model hatanın nedenini kendisi rapor edebilir.
3. Anthropic sağlayıcıda uzun bir plan yanıtı 1024 token'da kesilmez (istek `max_tokens` = registry değeri).
4. Ollama streaming modunda native tool call (`write_file` vb.) chunk'lardan kurtarılır ve yürütülür.
5. Aynı konuşmada art arda turlar (sticky açıkken) aynı provider/model'e gider; geçiş yalnızca `!model` veya yeni konuşma ile olur.
6. `!resume` sonrası Anthropic uç noktasında ardışık-rol 400 hatası alınamaz (sanitize testiyle sabit).
7. Mevcut 603+ test çalışması tamamen geçer; yeni test paketi eklenir.
