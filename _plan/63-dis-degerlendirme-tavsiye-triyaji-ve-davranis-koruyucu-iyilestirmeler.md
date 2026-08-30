# 63 — Dış Değerlendirme Tavsiye Triyajı: Kademeli Acil Sıkıştırma, Shell Kompozisyonu ve Maskeleme Hassasiyeti

**Durum:** 📋 **Planlandı** (uygulama onayı bekliyor) · **Zorluk:** Orta · **Öneri kaynağı:** Dış Değerlendirme Raporu — "✅ 9. Potential Concerns" tablosu (7 madde) · **Faz:** 6  
**İlgili Planlar:** [35](35-baglam-sikistirma-token-tahmini-ve-otomatik-truncation-politikasi.md) · [41](41-repl-komut-modulerizasyonu-domain-driven-command-decoupling.md) · [54](54-kod-sagligi-ve-modulerlik-dis-degerlendirme-bulgulari.md) · [59](59-cekirdek-guvenligi-sentez-sandbox-bare-rescue-ve-moduler-testler.md) · [61](61-llm-baglam-surekliligi-hata-turlerinde-kayit-ve-stream-butunlugu.md) · [62](62-rubocop-sifir-uyari-temizligi-davranis-koruyucu-kademeli-strateji.md) · [Index](index.md)

## 1. Amaç

Dış değerlendirme raporundaki 7 "Potential Concerns" maddesinin her birini **kanıta dayalı olarak** (dosya:satır referanslarıyla) triyaj etmek; **haklı bulunan** maddeleri davranış-koruyucu, kademeli ve test-kapılı iyileştirme fazlarına dönüştürmek; **haksız veya kazancı risksinden düşük** bulunan maddeleri gerekçeleriyle kayıt altına almak. Plan 62 disiplini aynen geçerli: nominal akışta sıfır davranış değişikliği, faz başına commit, her commit öncesi tam test + RuboCop kapısı.

---

## 2. Triyaj Sonuçları (7/7 madde karara bağlandı)

| # | Tespit (özet) | Hüküm | Birincil Kanıt | Karar |
|:--|:--------------|:-----:|:---------------|:------|
| 1 | `EmergencyCompactor` kritik yolda tool sonuçlarını 300, assistant mesajlarını 1000 karaktere kırpar → retry sırasında bağlam kaybı | 🟡 **Kısmen haklı** | `lib/rubik/prompt/emergency_compactor.rb:29-37`, `orchestrator/loop.rb:207-223`, `orchestrator/stream_manager.rb:55-65` | **Faz A** — kademeli tırmanma |
| 2 | `BaseProvider#complete` chunk'ları dizide toplayıp sonra birleştirir → büyük stream yanıtında bellek büyümesi | 🟢 Teorik; kazanç < risk | `llm/provider.rb:94-103`, `llm/chunk_assembler.rb:20-110` | Kapsam dışı — §7.1 |
| 3 | 8 dilin 6'sında regex tabanlı extractor; parse-tree doğruluğu yok; "Tree-sitter (Plan 18) entegrasyonu" önerisi | 🟡 Sınırlama gerçek, **öneri hatalı** | `_plan/18-...md` çıktısı; `lib/rubik/ast/*_extractor.rb` | Ertelendi — §7.2 |
| 4 | `Shell#initialize` 100+ satır, çok sayıda doğrudan inşaat → izole test zor | 🟡 **Haklı** (88 satır ölçüldü) | `repl/shell.rb:27-114` | **Faz B** — kompozisyon ayrıştırması |
| 5 | `LSP::Manager#all_diagnostics` tüm istemcilerden eşzamanlı toplar → orkestratör döngüsünü bloklayabilir | 🔴 **Haksız** (yanlış teşhis) | `lsp/manager.rb:219-229`, `lsp/client.rb:268-292`, `tools/builtins/lsp.rb:31` | Kapsam dışı — §7.3 |
| 6 | Anthropic system mesajları `\n\n` ile birleştiriliyor → "tek system mesajı beklentisini aşabilir" | 🔴 **Haksız** (kod zaten doğru) | `llm/anthropic.rb:33-42, 97-106` | Faz C-2 — yalnızca açıklama yorumu |
| 7 | `bearer\s+` mask deseni fazla geniş → düz metinde "bearer" maskelenir | 🟢 **Haklı** | `security/guard.rb:54-59`, `session/recorder.rb:11-20` | **Faz C-1** — desen hassasiyeti |

### 2.1 Madde 1 — EmergencyCompactor kör kırpması (🟡 kısmen haklı)

**Doğrulanan gerçekler:**

- Emergency yol **yalnızca** sağlayıcı `context|token limit` taşması hatası fırlattıktan sonraki **tek seferlik retry'da** devreye girer (`loop.rb:207-223` batch, `stream_manager.rb:55-65` stream) ve `context.auto_recover_on_overflow` (öntanımlı `true`) şartına bağlıdır.
- Kırpma **kör orta-kesim değil**: `Tools::Truncator.truncate(..., strategy: :head_tail)` baş + son korur ve atlanan satır/karakter sayısını bildirim olarak ekler (`tools/truncator.rb:37-55`).
- **Proaktif katman zaten var**: `BudgetManager#evaluate_context_compaction!` istek öncesi `ContextCompactor.compact_history` (hybrid: tool-result budama → sliding window → özet işareti → dev mesaj yarıya indirgeme) çalıştırır (`orchestrator/budget_manager.rb:32-48`, `prompt/context_compactor.rb:36-86`).
- **Asıl açık**: proaktif katman `@loop.context_limit` yoksa hiç çalışmaz (`budget_manager.rb:33`). Taşma hatası geldiğinde `EmergencyCompactor.compact!(@history)` ise parametresiz çağrılır ve **yapısal makineyi hiç kullanmadan** doğrudan 300/1000 karakterlik sert sınıra iner — mesaj bütünlüğü (ilk/son N korunumu, özet işareti, atomik birim gruplama) hiçe sayılır. Retry sonrası history kalıcı olarak hasarlı kalır; raporun "bağlam kaybı" tespiti bu yüzden haklıdır.

**Neden "kör kesim → LLM özetlemesi" önerisi değil:** acil durumda sağlayıcı az önce taşma hatası vermiştir; özetleme için tekrar çağırmak tavuk-yumurta döngüsüdür ve yeni bir ağ turu/gecikmesi ekler. Doğru düzeltme, **zaten kod tabanında duran yapısal makineyi** (`ContextCompactor`, `force: true`) sert kırpmanın **önüne** koymaktır → Faz A.

### 2.4 Madde 4 — Shell#initialize büyüklüğü (🟡 haklı)

`repl/shell.rb:27-114` = **88 satır** ("100+" ifadesi abartılı, yönü doğru) ve ~20 doğrudan `X.new` inşaatı. DI yalnızca 4 kwarg'ta (`config:`, `event_bus:`, `buffer_manager:`, `snapshot_store:`); AST graf, index, kayıtçı, registry'ler, router, runtime, overlay, LSP, guard, sandbox enjekte edilemiyor. `build_tool_registry` (`shell.rb:351-360`) `shell: self` geçtiği için Shell'e bağlı kalmalıdır; alt sistem inşaatı ise tamamen taşınabilir → Faz B.

### 2.6 Madde 6 — Anthropic system birleştirme (🔴 haksız)

Anthropic Messages API `system` alanını **üst düzeyde tek** bekler (string veya metin blokları dizisi). Mevcut kod (`anthropic.rb:33-42` batch, `97-106` stream) birden çok system mesajını tek dizeye birleştirip üst düzeye koyar ve boşsa alanı hiç göndermez — **tam olarak API sözleşmesinin istediği normalizasyon**. Raporun "beklentiyi aşabilir" varsayımı ters yönlüdür; değişiklik gerekmez, yalnızca sözleşmeyi açıklayan bir yorum eklenir (Faz C-2) ki gelecekte yanlış "düzeltme" girişimleri önlensin.

### 2.7 Madde 7 — bearer mask deseni (🟢 haklı)

`/bearer\s+[a-zA-Z0-9_\-.]+/i` (`guard.rb:58` denetim günlüğü maskesi, `recorder.rb:18` oturum günlüğü maskesi) düz metinde **"bearer of"** kalıbını bile yakalar → "the bearer of bad news" → "the ***MASKED*** bad news". Gerçek bearer taşıyıcıları (JWT ≥ 3 segment, opaque tokenlar) pratikte ≥ 20 karakterdir; `sk-...{20,}` deseniyle tutarlı bir alt sınır prose hasarını giderir → Faz C-1.

---

## 3. Uygulama Fazları

### Faz 0 — Baz ölçüm ve guard'lar

- [ ] `rake test` baz (Plan 62 kapanışı: 823 run / 4358 assertion / 0 failure) ve `rubocop` exit 0 kaydı.
- [ ] Faz A/B/C için etkilenen sembollerde GitNexus `impact` (yukarıyınlı): `EmergencyCompactor.compact!`, `Loop#execute_batch_request`, `StreamManager` retry bloğu, `Shell#initialize`, `Guard::MASK_PATTERNS`, `Recorder::MASK_PATTERNS`, `mask_text`.

### Faz A — Acil durum sıkıştırmada kademeli tırmanma (madde 1)

**Hedef:** taşma retry'ında önce yapısal sıkıştırma, sert kırpma yalnız son katman.

1. `EmergencyCompactor.compact!` imzası geriye uyumlu genişletilir:

```ruby
def compact!(history, context_limit: nil, max_output_tokens: nil, config: {})
  return history if history.nil? || history.empty?

  layer = :none
  if context_limit&.positive?
    structural = Rubik::Prompt::ContextCompactor.compact_history(
      history, context_limit: context_limit,
      max_output_tokens: max_output_tokens || 4096, config: config, force: true
    )
    history.replace(structural) # Array kimliği korunur — in-place kontrat bozulmaz
    layer = :structural
    still_over = Rubik::Prompt::ContextCompactor.needs_compaction?(
      history, context_limit: context_limit,
      max_output_tokens: max_output_tokens || 4096, config: config
    )
    return history unless still_over
  end

  # Katman 2 (son çare, mevcut davranış birebir): 300/1000 head_tail
  ...
  layer
end
```

2. İki çağrı noktası parametre geçirir:
   - `orchestrator/loop.rb:219` → `compact!(@history, context_limit: @context_limit, max_output_tokens: @max_output_tokens, config: @config ? @config.fetch("context", {}) : {})` (çağrı konvansiyonu: `budget_manager.rb:35-47` ile aynı).
   - `orchestrator/stream_manager.rb:62` → aynı parametreler `@loop` üzerinden.
3. `:emergency_compact` adım bildirimine eklemeli `layer: :structural | :hard_truncate | :none` anahtarı (mevcut tüketiciler bozulmaz; teşhis Plan 61 izleme hattıyla uyumlu).
4. **Bilinçli tutarlılık notları:** `compact_history` saf olduğundan mesaj hash'leri dup'lanır; `history.replace` yalnız `@history` **Array** kimliğini korur (mevcut in-place sözleşmesi budur — `stream_manager.rb:62` zaten mutasyon bekler). `config["compaction_strategy"] = "off"` tercihinde yapısal katman no-op döner ve Katman 2 devreye girer (kullanıcı tercihine saygı). `context_limit` yoksa (eski çağrılar/dış tüketiciler) davranış **birebir mevcut haliyle** kalır.

**Kabul:** `test/unit/test_emergency_compactor.rb` genişletme — (a) `context_limit` verilince intermediate tool sonuçları özet işaretiyle çöker, assistant içerikleri 1000'e KIRPILMAZ; (b) yapısal katman yetmezse (tek dev user mesajı) Katman 2 çalışır; (c) `context_limit: nil` → mevcut testler değişmeden geçer; (d) Array `object_id` korunumu; (e) `layer` bildirimi. Mevcut overflow-retry testleri (`test_orchestrator_stream.rb`, loop batch retry) aynen geçer.

### Faz B — Shell inşasının kompozisyona ayrıştırılması (madde 4)

**Hedef:** inşaat dışarı, koordinasyon Shell'de. **Saf taşıma — gözlemsel davranış birebir.**

1. Yeni `lib/rubik/repl/composition.rb`:

```ruby
module Rubik
  module REPL
    # Shell#initialize'ın inşaat yükünü taşıyan saf kompozisyon katmanı.
    # Sıra, Shell'deki tarihi inşaat sırasıyla birebir aynıdır.
    module Composition
      Parts = Struct.new(
        :buffer_manager, :snapshot_store, :cache_store, :ast_graph, :context_index,
        :recorder, :adapter_registry, :llm_registry, :router, :runtime_manager,
        :overlay_storage, :lsp_manager, :guard, :sandbox_runner,
        keyword_init: true
      )

      def self.build(config:, root_dir:, event_bus: nil, buffer_manager: nil, snapshot_store: nil)
        # ... mevcut initialize gövdesindeki inşaat sırası (event_bus → buffer →
        # snapshot → cache/ast → index → recorder → registry'ler → router →
        # runtime → overlay → lsp → guard → sandbox) birebir buraya taşınır.
        Parts.new(...)
      end
    end
  end
end
```

2. `Shell#initialize` (`repl/shell.rb:27`): mevcut 4 DI kwarg korunur ve `Composition.build`'e delege edilir; instance değişkenler `parts` üzerinden atanır. Ek opsiyonel `parts:` kwarg'ı test ikizleri için **tam** enjeksiyon sağlar.
3. **Shell'de kalır** (davranış sırası birebir korunmalı): enjekte edilmiş `buffer_manager` için ek root/dizin kaydı (`shell.rb:42-46`), senkron cache yüklemesi (`:58`), runtime `provide` blokları + AST/Index/Tool/Loop/Render servis kayıtları (`:78-96`), `build_tool_registry` (`shell: self` gerektirir), `Rubik.current_shell` / `Rubik.runtime_manager` atamaları, `overlay_storage.load_all` (`:113`), arka plan ısındırma başlatma (`:108-109`).
4. Meta-test uyumu: `test_module_hygiene` dosya/satır sınırları yeni dosya için doğrulanır; `test_repl_command_decoupling` (shell.rb < 600 satır) faz sonrası belirgin rahatlar (~510-530 beklenir).

**Kabul:** tüm mevcut Shell/REPL testleri değişikliksiz geçer; `rake test` 0 failure; `rubocop` exit 0; yeni `test/unit/test_repl_composition.rb` — parçalar stub'lanarak Shell'in alt sistem referanslarının tamamının enjekte edilebildiği ve sağlanmayan parçaların öntanımlı inşa edildiği gösterilir.

### Faz C — Maskeleme hassasiyeti ve sözleşme dokümantasyonu (madde 7 + 6)

1. **C-1 (davranışlı, test-kapılı):** her iki maske tablosunda (`guard.rb:58`, `recorder.rb:18`)
   `/bearer\s+[a-zA-Z0-9_\-.]+/i` → `/\bbearer\s+[a-zA-Z0-9_\-.]{20,}/i`
   — `\b` birleşik kelimelerde ("standardbearer") yanlış eşlemeyi önler; `{20,}` alt sınırı `sk-[a-zA-Z0-9_-]{20,}` ile tutarlıdır. Bilinçli ödün: 20 karakterden kısa gerçek token maskelenmez (pratikte böyle taşıyıcı yoktur; karar testlere ve bu belgeye işlenir).
2. **C-2 (kod değişikliği yok):** `anthropic.rb:33` ve `:97` üstüne tek satır açıklama — "Anthropic Messages API tek üst düzey `system` alanı bekler (string veya metin blokları); çoklu system mesajları bilinçli olarak tek dizeye birleştirilir."

**Kabul:** guard + recorder mask testleri — "the bearer of bad news" ve "Bearer rights and duties" değişmez; `Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig` maskelenir; mevcut `sk-`/`ghp_` v.b. maskeleri değişmez.

---

## 4. Genel Kabul Kriterleri

- [ ] 7/7 madde bu belgedeki gerekçeleriyle karara bağlandı (§2) — uygulama sırasındaki sapmalar belgeye işlenir.
- [ ] Nominal akışta (taşma hatası yok, maskeleme girdisi yok) **sıfır** davranış değişikliği; yalnızca Faz A acil-durum yolu (daha az yıkıcı) ve Faz C-1 maske deseni bilinçli ve test-kapılı değişir.
- [ ] Her faz ayrı commit; her commit öncesi `rake test` 0 failure + `rubocop` exit 0 + GitNexus `detect_changes` (beklenen semboller dışı etki yok).
- [ ] Mevcut 823 run / 4358 assertion bazı korunur veya yalnızca yeni testlerle artar.
- [ ] `AGENTS.md` / `CLAUDE.md` çalışma ağacı değişiklikleri hiçbir commit'te stage edilmez (Plan 62 disiplini).

## 5. Test Stratejisi

- **Faz A:** `test_emergency_compactor.rb` (5 yeni vaka) + mevcut retry e2e'leri regresyon kapısı.
- **Faz B:** yeni `test_repl_composition.rb` + mevcut REPL/Shell suiti değişikliksiz (saf taşıma kanıtı).
- **Faz C:** guard/recorder mask birim testleri (proze korunumu + gerçek token maskesi).
- Her faz sonunda tam `rake test`; kapanışta `rubocop` ve meta-testler (`test_module_hygiene`, `test_repl_command_decoupling`).

## 6. Riskler ve Geri Alma

| Risk | Olasılık | Etki | Mitigasyon |
|:-----|:--------:|:----:|:-----------|
| Faz A: yapısal katman taşma retry'ını kurtaramaz | Orta | Düşük | Katman 2 aynı kalır; retry zaten tek seferlik, başarısızlıkta hata aynen yükselir |
| Faz A: `history.replace` semantiği dış çağıranı şaşırtır | Düşük | Orta | Array kimliği korunur; kontrat testi (d); plan notu §3-Faz A-4 |
| Faz B: inşaat sırası kayması gözlemsel fark yaratır | Düşük | Orta | Sıra birebir taşınır; Shell testleri değişikliksiz geçmek zorunda |
| Faz C-1: kısa gerçek token maskelenmez | Düşük | Düşük | `{20,}` eşiği belgeli; ileride entropi-tabanlı desen değerlendirilebilir |
| Genel: davranış kaybı | — | — | Faz bazlı commit → `git revert` ile atomik geri alma |

## 7. Kapsam Dışı / Ertelenenler

### 7.1 Madde 2 — `BaseProvider#complete` chunk tamponu (teşhis kısmen doğru, öneri reddedildi)

`ChunkAssembler` üç ayrı geçişte chunk'ların **tamamına** ihtiyaç duyar: (1) `text_delta` birleştirme, (2) `tool_use_delta` işleme — `args_json` parçaları olay sırasına göre **birikerek** birleşir (`chunk_assembler.rb:29-40`), (3) `raw` olay taraması (`content_block_start`, `message.tool_calls`) + `last_raw`/`usage` çözümü (`:42-62, 99-113`). "Doğrudan buffer'a akıtmak" ya bu invariantları kırar ya da assembler'ın ikinci bir artımlı kopyasını gerektirir. Plan 61 D-4'ün temel invariantı (batch ve stream yolları özdeş `text`/`tool_calls`/`usage` üretir) kasıtlı olarak riske atılmaz. LLM yanıtları KB–yüz-KB ölçeğinde olduğundan peak bellek artışı (~2×) marjinaldir. **Yeniden değerlendirme tetikleyicisi:** gerçek bir bellek profili (benchmark) sorunu göstermesi.

### 7.2 Madde 3 — dil çıkarıcı doğruluğu (sınırlama gerçek; öneri hatalı; ertelendi)

Rapor "Tree-sitter entegrasyonu (Plan 18)" öneriyor, ancak **Plan 18 tree-sitter native binding içermeksizin** tamamlandı: regex tabanlı Go/Rust/Zig/C/Python çıkarıcıları + LSP köprüsü + artımlı indeks (Plan 18 çıktı bölümü; `lib/rubik/ast/` altında tree-sitter referansı yok). Gerçek tree-sitter = yeni native gem + dile özgün parser kütüphaneleri + Windows-first derleme hattı (Plan 49 kısıtları) → **ayrı bir plan konusudur** (gerektiğinde "Plan 64+"). Ucuz ara iyileştirmeler (satır aralığı doğruluğu için bulgu bazlı yamalar) Plan 59/60 yaklaşımıyla ileride işlenebilir.

### 7.3 Madde 5 — `all_diagnostics` bloklama iddiası (haksız)

`Client#all_diagnostics` yalnızca `@diagnostics.dup` yapar — mutex altında mikrosaniyelik hash kopyası (`lsp/client.rb:268-272`). Tanılamalar **push tabanlıdır**: arka plan reader thread'i `textDocument/publishDiagnostics` bildirimleriyle tabloyu güncel tutar (`client.rb:276-292`); toplama sırasında **hiçbir IPC/istek yapılmaz**. Çağıran taraf da orkestratör döngüsünün kendisi değil, ajanın çağırdığı `lsp_diagnostics` aracıdır (`tools/builtins/lsp.rb:31`). Önerilen "async toplama" var olmayan sorunu çözerdü; değişiklik gerekmez.

## 8. Uygulama Disiplini

- Faz sırası: **A → B → C** (A kullanıcı değeri en yüksek ve dar kapsamlı; B en geniş ama saf taşıma; C en küçük).
- Her sembol düzenlemesi öncesi GitNexus `impact` (MCP erişimi yoksa `.gitnexus/run.cjs` CLI'si), her commit öncesi `detect_changes` — Plan 62'deki gibi raporlanır.
- Commit mesajları: `feat(prompt): ... (Plan 63 Faz A)` / `refactor(repl): ... (Plan 63 Faz B)` / `fix(security,session): ... (Plan 63 Faz C)` biçiminde.
