# Test Kılavuzu

> Bu belge, [`TESTING.md`](TESTING.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

Bu depoda testlerin nasıl çalıştırılacağını, adlandırılacağını ve yazılacağını anlatır. Suite, Rake ile yürütülen Minitest'tir (`~> 5.20`); her zaman bundler üzerinden çalıştırın (bkz. `test/test_helper.rb` içindeki shield — Ruby ≥ 4.0'ın varsayılan minitest 6'sı suite'i kırar).

## Testleri Çalıştırma

| Komut | Ne yapar |
| --- | --- |
| `bundle exec rake test` | Tam suite (unit + integration), serial loader — referans koşu |
| `bundle exec rake` | Aynı tam suite, tek süreçli loader'lar üzerinden (`test:unit_once` + `test:integration`) |
| `bundle exec rake test:fast` | Unit testler eksi ölçülmüş 16 yavaş dosya (≈2640 koşu, ~6 dk) |
| `bundle exec rake test:slow` | Yalnızca izole edilmiş yavaş unit dosyaları |
| `bundle exec rake test:unit` / `test:integration` | Yalnızca tek dizin ağacı |
| `bundle exec rake test:parallel[4]` | N paralel worker süreci; geliştirme makinesinde **N=4, ölçülmüş tek 0 hatasız yapılandırma** (6/8'i timing-kırılgan testleri tetikler) |
| `bundle exec rake test:profile` | Dosya başına wall-time profili → `_report/unit_profile.csv`; sleep/thread-ağır testlere dokunduktan sonra yenileyin, ardından `Rakefile` içindeki `SLOW_UNIT_FILES` listesini güncelleyin |
| `bundle exec rake test:badge` | Tam suite'i çalıştırır ve README test badge'ini (`tests-<N> runs`) gerçek Minitest özetlerinden yeniden yazar; kırmızı suite'i reddeder (`dev/update_test_badge.rb`) |
| `bundle exec ruby -Ilib -Itest test/unit/test_x.rb` | Tek dosya, en hızlı geri bildirim döngüsü |

Pratik kurallar: geliştirme yaparken tek dosyaya odaklanın; commit öncesi `rake test:fast` çalıştırın; refactor gate'leri için tam `rake test` çalıştırın.

## Adlandırma Kuralları (G15)

**Dosyalar**, davranışa göre değil *test edilen özneye* göre adlandırılır: `test_<subject>.rb`. Özne tek bir şeyse tekili kullanın (`test_activity_log.rb`); çoğulu yalnızca özne *doğuştan* bir koleksiyon ya da sayılamayan bir topluluk adıysa kullanın:

- Koleksiyonlar (çoğul doğrudur): `test_sandbox_drivers`, `test_llm_stream_providers`, `test_repl_hooks`, `test_ui_approvals`.
- Sayılamayan adlar (mass nouns; `-s` ile bitmek çoğul değildir): `test_lsp_robustness`, `test_exec_tools_diagnostics`, `test_synthesis`, `test_event_bus`.
- Config anahtarı yansımaları anahtarın kendi yazımını korur: `test_allowed_external_dirs`.
- Özne-aspekt bileşikleri (`test_<subject>_<aspect>.rb`), aspekt dosyanın varoluş gerekçesi olduğunda uygundur — error-path ailesi: `test_lsp_client_error_paths`, `test_buffer_snapshot_failures`. Önce özne, sonra aspekt; asla yalın bir davranış adı kullanmayın.

O sırada var olan 28 `s` ile biten unit dosyasının 2026-09-29 tarihli denetimi ile o zamandan beri eklenen 7 dosyanın 2026-09-30 tarihli yeniden denetimi de yalnızca koleksiyon, sayılamayan-ad, anahtar-yansıması ya da özne-aspekt adları buldu — yeniden adlandırma gerekmedi. Yukarıdaki kural yeni dosyalar için standarttır; mevcut adları mekanik olarak tekilleştirmeyin.

**Test metotları** mekaniği değil davranışı ifade eder: `test_extend_budget` yerine `test_agent_extends_budget_when_user_approves` tercih edin. Tesadüfi sayaçları değil sonuçları (diskteki durum, dönüş sözleşmeleri, kullanıcıya görünen etkiler) assert edin — örneğin bir döngünün `result[:steps]` değerini kesin bir tur sayısına değil bütçesine bağlayın (`test/integration/test_e2e_agent_workflow.rb`).

## Şablonlar

### Unit test

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

class TestSomething < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubik_something")
  end

  def teardown
    remove_temp_dir(@dir)  # Windows-safe removal (EACCES retry built in)
  end

  def test_subject_behaves_expected_way_under_condition
    subject = Rubik::Subject.new(root_dir: @dir)

    result = subject.call

    assert result[:ok], "expected ok result"
  end
end
```

### Agent-loop entegrasyon testi

Paylaşılan harness'i kullanın (`test/support/scripted_agent_harness.rb`) — config, buffer manager, context index ve varsayılan tool registry'yi birbirine bağlar; senaryolu asistan turlarını sahte bir sağlayıcı üzerinden oynatır:

```ruby
def test_agent_fixes_file_bug_e2e
  responses = [
    { role: "assistant", content: '{"tool": "read_file", "args": {"path": "lib/x.rb"}}' },
    { role: "assistant", content: '{"tool": "finish", "args": {"message": "done"}}' }
  ]

  harness = Rubik::TestSupport::ScriptedAgentHarness.build_agent_loop(
    root_dir: @dir,
    responses: responses,
    files: { "lib/x.rb" => "class X\nend\n" }
  )

  result = harness.agent_loop.run("fix lib/x.rb")

  assert result[:ok]
  assert_operator result[:steps], :<=, harness.agent_loop.max_steps
end
```

Script tükendiğinde harness bir `finish` çağrısı döndürür; böylece yetersiz senaryolu testler nil deref'te değil kendi assertion'larında başarısız olur.

## Bilinen flake'ler ve politika (G18)

- **Open3 `IOError: stream closed in another thread`** (Ruby ≤ 3.4): kozmetik, koşu başına 0–2 kez, assertion'ları etkilemez. Bilinçli olarak *filtrelenmez* — gerekçe `test/test_helper.rb` içinde. Ruby 3.5+ ile upstream'de düzeltildi.
- **Windows geçici dizin silme** (teardown sırasında `Errno::EACCES`): teardown'da `remove_temp_dir` kullanın (`test/test_helper.rb` içindeki retry yardımcısı), asla ham `FileUtils.remove_entry` kullanmayın.
- **Timing-kırılgan testler** (sleep/thread-ağır) silinmek yerine `SLOW_UNIT_FILES` içinde karantinaya alınır; yine de `rake test`, `test:slow` ve CI-parite tam koşularda çalışır.
- **Şüpheliyi yoklayın**: `bundle exec ruby dev/rerun_flaky.rb test/unit/test_x.rb 5` bir dosyayı taze süreçlerde yeniden çalıştırır, geçme sayısını ve wall-time yayılımını raporlar ve herhangi bir başarısızlıkta sıfırdan farklı çıkış koduyla döner. Bir kez bile başarısız olan dosya `test:profile`'dan geçirilir; ya yarışın (race) olduğu noktada düzeltilir ya da karantinaya alınır. Flakiness asla assertion'ın içine gömülmüş retry'larla kapatılmaz.

## İzolasyon: ağ, socket'ler, terminal ortamı (issue #148)

Unit testler dış dünyaya bağlı olmamalıdır: DNS/internet yok, sağlayıcı API anahtarı yok, devralınan terminal durumu yok ve test sırasına bağımlılık yok.

- **Transport/pool enjeksiyonu.** LLM client'ını çalıştıran testler bağlanmak yerine sahte transport enjekte eder: `http_factory:` kullanın (`test_llm_connection_pool.rb` içindeki factory testleri) veya havuzlanmış transport'u sabitleyen çağrı yolları için pool seam'ini (`HTTPClient.with_pooled_connection`) stub'layın (`test_llm_retry.rb`'deki idle-timeout testi sıfır bağlantıyla timeout değerini yine doğrular). Unit testler `Net::HTTP` tümüyle bloke edilmişken de geçer: `bundle exec ruby -Ilib -Itest -e 'class Net::HTTP; def start(*) = raise; def request(*) = raise; end; require "./test/unit/test_llm_retry.rb"'`.
- **Ortam snapshot/restore.** `NO_COLOR`, `CLICOLOR_FORCE`, `TERM` veya `RUBIK_TEST`'e dokunan testler anahtarları `setup`'ta snapshot'lar (`snapshot_env`) ve `teardown`'da geri yükler (`restore_env`, ikisi de `test/test_helper.rb`) — varlık *ve* değer, unset-empty ayrımı dahil. Silmek yerine geri yüklememek devralınan ortamı sonraki testlere sızdırır ve suite'i sıraya bağımlı yapar. Renk testleri dış kabuk `NO_COLOR` export etse de etmese de geçer (ürün önceliği: `NO_COLOR`, `CLICOLOR_FORCE`'u yener).
- **Socket gerektiren testler varsayım değil önkoşuldur.** Loopback socket'leri bir yetenektir: `localhost_socket_error` ile yoklayın (`test/test_helper.rb`) ve gerçek hatayla `skip`'i yalnızca canlı sunucuya ihtiyaç duyan testlerde kullanın — aynı dosyadaki sahte-transport testleri çalışmaya devam eder ve bir ürün assertion hatası asla skip arkasına saklanmaz. Teardown nil-güvenli olmalıdır (`@server&.shutdown`), böylece başarısız bir setup tek net hata üretir, ikincil bir `nil.shutdown` hatası değil. Bu testleri şöyle çalıştırın: `bundle exec ruby -Ilib -Itest test/unit/test_llm_connection_pool.rb`; socket oluşturmayı yasaklayan sandbox'larda 3 skip sandbox gerekçesiyle raporlanırken enjekte-transport testleri yine geçer.
- **Ayrım gözetmeyen skip yok.** Skip, eksik bir ortam yeteneği (socket kısıtı, olmayan opsiyonel binary) için saklıdır ve mesajında somut hatayı taşır; davranış/assertion sorunları düzeltilir, asla skip edilmez.

## Benchmark'lar (G14)

`bundle exec rake bench` birleşik benchmark raporunu çalıştırır. Odaklı yük scriptleri `dev/` altındadır: `bench_ast_index.rb` (tüm ağaç üzerinde semantic-index oluşturma + arama — cold-build yük testi), `bench_ast_extractors.rb` (dosya başına extraction maliyeti dökümü), `bench_context_scan.rb`, `bench_native_tools.rb`, `bench_rg_flag_cost.rb` ve `benchmark/tool_latency.rb`. Kalıcı AST önbelleği ayrıca suite içi bir yük koruması taşır (`test_ast_persistent_cache.rb` yüksek hacimli testi); bu testin wall-time assertion'ını makineye duyarlı sayın — paralel yük altındaki bir başarısızlığa inanmadan önce onu izole olarak yeniden çalıştırın (`dev/rerun_flaky.rb`).

## Yaşam döngüsü soak (G26)

Ω zero-restart denetimi (AGENTS.md §6): `Context`/`ComponentFiber`'ı N yaşam döngüsü epoch'undan geçirin ve akümülatörün taban durumuna döndüğünü, her inverse'in tam olarak bir kez çalıştırıldığını doğrulayın. Dört aile — context epoch'ları (extend/dispose), service epoch'ları (provide takası/unprovide), fiber aktivasyon döngüleri, aktivasyon-başarısızlığı rollback'i — iki biçimde:

- **Guard (suite):** `test/unit/test_runtime_zero_restart_soak.rb`, dört sözleşmeyi suite'e uygun epoch sayılarında sabitler; her fast geçişte çalışır.
- **Probe (ölçek):** `bundle exec ruby dev/soak_lifecycle.rb [epochs=1000]` aynı aileleri soak ölçeğinde, aile başına wall time bilgisiyle çalıştırır ve herhangi bir sızıntıda sıfırdan farklı çıkış koduyla döner. `lib/rubik/runtime/` altında (Context, ComponentFiber, Manager) yapılan her değişiklikten sonra ya da yeni bir component sınıfı eklerken çalıştırın.

## Coverage (G17) — CI'ya bağlı

Coverage enstrümantasyonu `RUBIK_COVERAGE=1` arkasında bulunur: `simplecov`, Gemfile'ın dev/test grubunda durur (`require: false`) ve `test/test_helper.rb`, herhangi bir rubik kodu yüklenmeden önce onu başlatır. Env değişkeni olmadan yapılan yerel koşular değişmeden kalır.

`.github/workflows/ci.yml`, rubocop'u (lib/) ve TAM suite'i — önce `test:fast`, ardından `test:slow` içindeki `SLOW_UNIT_FILES`, sonra `test:integration` — coverage açık şekilde çalıştırır ve HTML/JSON raporunu `coverage-report` artifact'i altında yayımlar. Bu, `test_mcp_manager_composability`'nin iki gün boyunca gerilemesine izin veren kör noktayı kapattı: slow dışında bırakılan dosyaları düzenli olarak çalıştıran hiçbir şey yoktu.

Her CI adımı kendi simplecov komut adı altında raporlar (`RUBIK_COVERAGE_SUITE` = fast/slow/integration): tek bir paylaşılan adla her suite'in çıkışı, `.resultset.json` içindeki önceki suite'in girdisinin üzerine yazardı; böylece artifact yalnızca en son çalışan suite'i tarif ediyordu. Farklı adlar, SimpleCov'un üç suite'i de nihai raporda birleştirmesini sağlar. Yerel eksik (gap) analizi için her suite'in ardından `coverage/.resultset.json` dosyasının anlık görüntüsünü alın ve birleşimi kendiniz oluşturun (her `RUBIK_COVERAGE_SUITE` değeri için bir suite).

CI lint adımı çıplak bir `bundle exec rubocop`'tur — tüm depoyu kapsar (534 dosya: `lib/`, `test/`, Rakefile, benchmark); test ağacının eski style borcunu (~57 offense, çoğu otomatik düzeltilebilir) temizleyen 2026-09-30 geçişinden bu yana sıfır offense. Bakılacak ayrı bir kapsam yok: herhangi bir yerdeki yeni bir offense push CI'ı düşürür; borç bu yüzden sessizce yeniden birikemez.
