# 📋 Plan 84: Model Context Protocol (MCP) İstemcisi ve Spatiotemporal Dinamik Araç Entegrasyonu

> **Protokol:** [`AGENTS.md`](../AGENTS.md) — Spatiotemporal Composability & Self-Evolving Runtimes  
> **Durum:** 🟢 **Tamamlandı** · **Zorluk:** İleri · **Faz:** 6  
> **İlgili Planlar:** [10](10-tool-calling-orkestrasyon.md), [14](14-eklenti-sistemi.md), [17](17-yerel-arac-cagrilari-ve-router.md), [20](20-spatiotemporal-composability-eklenti-dongusu.md), [24](24-kendi-kendine-evrilen-arac-sentezi-ve-calisma-zamani-denetimi.md), [29](29-lsp-derin-entegrasyonu-tanilama-ve-reaktif-geri-bildirim.md), [56](56-frontier-agentic-tool-contracts-ve-elm-tarzi-yonlendirici-hata-mimarisi.md), [73](73-arac-katmani-sertlestirme-kapsulleme-ve-hata-ayristirma.md), [83](83-dis-denetim-iyilestirmeleri-managed-threads-test-teshis-ve-fiber-guvenligi.md)

---

## 🎯 1. Problem ve İhtiyaç Analizi

Rubik, halihazırda 22 yerleşik araca ([`Rubik::Tools::Registry`](../lib/rubik/tools/registry.rb)) ve çalışma zamanında dinamik araç sentezleme ([`SynthesizeToolTool`](../lib/rubik/tools/builtins/lifecycle.rb)) yeteneğine sahiptir. Ancak günümüz modern AI ajan ekosisteminde harici servisler, veritabanları (PostgreSQL, SQLite), arama motorları (Brave, Google), sürüm kontrol sistemleri (GitHub, GitLab), tarayıcı otomasyonları (Playwright, Puppeteer) ve yüzlerce üçüncü taraf araç **Model Context Protocol (MCP)** standardı etrafında birleşmiştir.

### Mevcut Kısıtlar:
1. **Kapalı Araç Havuzu:** Harici bir aracı Rubik'e entegre etmek için ya özel bir Ruby eklentisi yazılması (`lib/rubik/plugin/`) ya da LLM tarafından dinamik sentezlenmesi gerekmektedir. Hazır açık kaynaklı MCP sunucularını doğrudan kullanamamaktadır.
2. **Spatiotemporal Composability İhtiyacı ([`AGENTS.md`](../AGENTS.md)):** Harici araçlar çalışma zamanında bağlandığında, süreçlerinin (process lifecycle), pipe'larının ve JSON-RPC soketlerinin LIFO akümülatörü ($\Omega$) ile deterministik biçimde yönetilmesi şarttır. Bir MCP sunucusunun çökmesi veya bağlantısının kopması durumunda ajan oturumunun bozulmaması, ters işlemlerle kayıtlı araçların anında temizlenmesi ve sıfır sızıntı garantisi sağlanmalıdır.
3. **Dinamik Tak-Çıkar Yeteneği (Zero-Downtime Tool Swapping):** Kullanıcı veya ajan, REPL oturumunu yeniden başlatmadan yeni bir MCP sunucusunu bağlayabilmeli (`!mcp connect`), araçlarını sistem istemine ve tool listesine anında enjekte edebilmeli ve istediğinde tek komutla (`!mcp disconnect`) ardında çöp bırakmadan sökebilmelidir.

---

## 🏛️ 2. Mimari Tasarım ve Spatiotemporal Entegrasyon

```
                                ┌─────────────────────────────────────────┐
                                │             Rubik REPL / LLM            │
                                └────────────────────┬────────────────────┘
                                                     │ Tool Call
                                                     ▼
                                ┌─────────────────────────────────────────┐
                                │          Rubik::Tools::Registry         │
                                │   (Builtin Tools + Dynamic MCP Proxies) │
                                └────────────────────┬────────────────────┘
                                                     │ proxy.execute(args)
                                                     ▼
                                ┌─────────────────────────────────────────┐
                                │        Rubik::MCP::ProxyTool            │
                                │    (Schema Mapping & Call Forwarding)   │
                                └────────────────────┬────────────────────┘
                                                     │ client.call_tool(...)
                                                     ▼
                                ┌─────────────────────────────────────────┐
                                │          Rubik::MCP::Client             │
                                │    (JSON-RPC 2.0 & Handshake Engine)    │
                                └────────────────────┬────────────────────┘
                                                     │ Stdio Transport
                                                     ▼
                                ┌─────────────────────────────────────────┐
                                │     External MCP Server (Subprocess)    │
                                │   (e.g., npx -y @modelcontextprotocol/  │
                                │         server-filesystem /tmp)         │
                                └─────────────────────────────────────────┘
```

### AGENTS.md Protokolü Uyumluluğu:

```
                            ┌────────────────────────────────────────┐
                            │          Root Runtime::Context         │
                            └───────────────────┬────────────────────┘
                                                │ ctx.extend
                                                ▼
                            ┌────────────────────────────────────────┐
                            │    Scoped MCP Server Sub-Context       │
                            ├────────────────────────────────────────┤
                            │ • Ω Inverses Registered:               │
                            │   1. registry.unregister("mcp_...")    │
                            │   2. client.stop (close pipes, kill)   │
                            │   3. services.delete("mcp:server_name")│
                            │ • Coeffect Provided:                   │
                            │   ctx.provide("mcp:server_name", client│
                            └────────────────────────────────────────┘
```

1. **Revertible Effects ($\Omega$ LIFO):**
   - Her MCP sunucusu, kök bağlamdan türetilen bir alt bağlam (`server_ctx = ctx.extend`) içerisinde başlatılır.
   - Sunucunun keşfettiği (`tools/list`) her araç, `Rubik::MCP::ProxyTool` olarak sarılır ve `Tools::Registry`'ye kaydedilir.
   - Araç kaydı yapılır yapılmaz ters işlemi (`server_ctx.on_dispose { registry.unregister(proxy_tool.name) }`) akümülatöre eklenir.
   - İletişim süreci için `server_ctx.on_dispose { client.stop }` ters işlemi LIFO'ya kaydedilir.
   - Sunucu kapatıldığında veya bağlam dispose edildiğinde, önce araçlar kayıt defterinden silinir, ardından iletişim pipe'ları kapatılır ve alt süreç temizce sonlandırılır.
2. **Atomic Failure Rollback:**
   - Sunucu başlatma (spawn) veya `initialize` JSON-RPC el sıkışması aşamasında herhangi bir zaman aşımı veya hata oluşursa, `server_ctx.dispose` derhal tetiklenir; sistem tam olarak önceki temiz durumuna döner.
3. **Reactive Coeffects ($\Sigma \vdash C : \tau$):**
   - Aktif MCP sunucuları `ctx.provide("mcp:#{server_name}", client)` ile birer servis olarak çalışma zamanına sunulur.
   - Sunucu çökerse veya bağlantı koparsa durum reaktif olarak algılanır, araçlar ajan yüzeyinden geri çekilir.

---

## 🔧 3. Teknik Bileşenler ve Uygulama Adımları

### A. JSON-RPC 2.0 Taşıyıcı ve İstemci (`lib/rubik/mcp/`)

1. **`Rubik::MCP::Transport::Stdio` (`lib/rubik/mcp/transport/stdio.rb`):**
   - `Open3.popen3` ile alt süreci başlatır.
   - Plan 83 ilkelerine uygun yönetilen thread'ler (`@reader_thr`), thread-safe mutex/condition variable senkronizasyonu.
   - Satır bazlı (veya Content-Length başlıklı) JSON-RPC 2.0 istek, yanıt ve bildirim ayrıştırması.
   - `close`: Pipe'ları kapatır, alt süreci `Platform.kill_tree` ile öldürür, reader thread'ini `join(0.5)` ile güvenle bekler.
2. **`Rubik::MCP::Client` (`lib/rubik/mcp/client.rb`):**
   - `initialize(command, args: [], env: {}, name: "unnamed")`
   - `start!`: Taşıyıcıyı açar, `initialize` isteği gönderir (`protocolVersion: "2024-11-05"`), `notifications/initialized` bildirimini iletir.
   - `list_tools`: `tools/list` JSON-RPC çağrısı yapar, dönen araç şemalarını normalize eder.
   - `call_tool(tool_name, arguments)`: `tools/call` çağrısı yapar, `content` ve `isError` sonucunu string olarak paketler.
   - `ping`: Bağlantı canlılık kontrolü.
3. **`Rubik::MCP::ProxyTool < Rubik::Tools::Base` (`lib/rubik/mcp/proxy_tool.rb`):**
   - Her harici MCP aracını Rubik'in `Tools::Base` sözleşmesine uyarlar:
     - `name`: `mcp_{server_name}_{mcp_tool_name}` (çakışma önleyici ad alanı).
     - `description`: Sunucudan gelen açıklama + `[MCP: #{server_name}]` etiketi.
     - `parameters`: Sunucudan gelen JSON Schema (`inputSchema`).
     - `execute(args)`: `client.call_tool(original_name, args)` üzerinden çalıştırır ve standart ajan formatında döndürür.

### B. MCP Yöneticisi (`Rubik::MCP::Manager`) ve Durum Makinesi

- **`lib/rubik/mcp/manager.rb`:**
  - Birden fazla MCP sunucusunu ve durumlarını yönetir (`@servers = {}`, `@contexts = {}`, `@statuses = {}`).
  - **Sunucu Durumları:**
    - `:active` — Süreç ayakta, el sıkışıldı, araçlar `Tools::Registry`'de kayıtlı.
    - `:disabled` (`:pending`) — Yapılandırma tanımı saklı, süreç durdurulmuş, araçlar registry'den çekilmiş (sıfır kaynak).
    - `:failed` — Başlatma veya çalışma anında hata vermiş; kısmi ters işlemler geri alınmış.
  - **Yaşam Döngüsü Metotları:**
    - `add_server(name, defn, auto_start: true, persist: nil)`: Yapılandırmaya kaydeder, `auto_start` ise aktive eder.
    - `remove_server(name, persist: nil)`: Sunucuyu tamamen durdurur, LIFO ters işlemlerini çalıştırır ve yapılandırmadan siler.
    - `enable_server(name)`: `:disabled` durumdaki sunucuyu yeni bir alt bağlamda (`ctx.extend`) ayağa kaldırır, araçları kaydeder (`:pending` -> `:active`).
    - `disable_server(name)`: Sunucunun alt bağlamını (`server_ctx.dispose`) tetikler; araçlar kayıt defterinden çekilir, süreç kapatılır ama yapılandırma tanımı korunur (`:active` -> `:disabled`).
    - `connect(name, command, args: [], env: {}, ctx: nil)`: Oturumluk dinamik bağlantı açar.
    - `disconnect(name)`: Oturumluk bağlantıyı söker.
    - `load_from_config(config)`: `config.fetch("mcp.servers", {})` altındaki sunucuları otomatik yükler (varsayılanı `enabled: true` olanlar).

### C. REPL `!mcp` Komutu (`lib/rubik/repl/commands/mcp.rb`)

Kullanıcının ve ajanın REPL içerisinden MCP sunucularını anında yönetebilmesi için zengin komut seti:

| Komut | Açıklama |
| :--- | :--- |
| `!mcp` / `!mcp status` | Tüm kayıtlı MCP sunucularını, durumlarını (`[ACTIVE]`, `[DISABLED]`, `[FAILED]`), komutlarını ve araç sayılarını listeler. |
| `!mcp list [name]` | Aktif sunuculardan enjekte edilen araçların listesini ve şema parametrelerini gösterir. |
| `!mcp add <name> <cmd> [args...] [-p\|-g]` | Yeni bir MCP sunucusunu yapılandırmaya ekler (`--project` veya `--global` kalıcılığıyla) ve hemen aktive eder. |
| `!mcp remove <name> [-p\|-g]` | MCP sunucusunu çalışma zamanından söker ve kalıcı yapılandırmadan siler. |
| `!mcp disable <name>` (veya `!mcp off`) | Sunucuyu **silmeden devre dışı bırakır** (`:active` -> `:disabled`). Süreç sonlandırılır, araçlar ajan yüzeyinden çekilir. |
| `!mcp enable <name>` (veya `!mcp on`) | Devre dışı bırakılmış bir sunucuyu **yeniden aktive eder** (`:disabled` -> `:active`). Araçlar anında tekrar ajan yüzeyine eklenir. |
| `!mcp connect <name> <cmd> [args...]` | Geçici (yalnızca mevcut oturum için) bir MCP sunucusuna anında bağlanır. |
| `!mcp disconnect <name>` | Geçici veya çalışan bir MCP sunucusunu çalışma zamanından ayırır. |
| `!mcp ping <name>` | Sunucuya ping JSON-RPC isteği gönderip canlılık ve gecikme süresini ölçer. |

### D. Yapılandırma Desteği (`CONFIG.md` & `lib/rubik/config/defaults.rb`)

```yaml
mcp:
  enabled: false
  servers:
    filesystem:
      command: "npx"
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    fetch:
      command: "uvx"
      args: ["mcp-server-fetch"]
```
*(Not: `test_module_hygiene.rb` gereği `config/defaults.rb < 150 satır` kuralı korunacaktır).*

### E. Atıf ve Dokümantasyon (`ATTRIBUTION.md` & `README.md`)

- `ATTRIBUTION.md` dosyasına Model Context Protocol (Anthropic, PBC) atfı geri eklenir.
- `COMMANDS.md`, `TOOLS.md` ve `ARCHITECTURE.md` dosyalarına MCP istemci mimarisi eklenir.

---

## 🧪 4. Test Stratejisi ve Doğrulama

1. **Birim Testleri (`test/unit/test_mcp_client.rb`):**
   - Mocked/Pipe tabanlı JSON-RPC 2.0 handshake, initialize, tool listing ve tool call testleri.
   - Hata durumları (geçersiz JSON, sunucu çökmesi, zaman aşımı).
2. **Spatiotemporal Composability Testleri (`test/unit/test_mcp_composability.rb`):**
   - Sunucu bağlandığında araçların `Tools::Registry`'ye eklendiği,
   - `server_ctx.dispose` çağrıldığında LIFO sırasıyla araçların unregister edildiği ve sürecin kapatıldığı,
   - Handshake hatası durumunda atomic rollback yapıldığı ve ortamda yetim süreç/araç kalmadığı.
3. **REPL Entegrasyon Testleri (`test/unit/test_repl_mcp_command.rb`):**
   - `!mcp`, `!mcp connect`, `!mcp disconnect` komutlarının REPL döngüsündeki davranışı.
4. **Regresyon:**
   - 1,320 mevcut testin tamamının %100 yeşil kalması.
   - RuboCop 0 offense.

---

## 📋 5. Uygulama Adımları

- [x] **Adım 1:** `lib/rubik/mcp/transport/stdio.rb` ve `lib/rubik/mcp/client.rb` sınıflarını oluştur.
- [x] **Adım 2:** `lib/rubik/mcp/proxy_tool.rb` adaptörünü yaz.
- [x] **Adım 3:** `lib/rubik/mcp/manager.rb` orkestratörünü Spatiotemporal Context entegrasyonuyla geliştir.
- [x] **Adım 4:** `lib/rubik/config/defaults.rb` içine `mcp` yapılandırmasını ekle (satır sınırı hijyeni).
- [x] **Adım 5:** REPL `!mcp` komutunu `lib/rubik/repl/commands/mcp.rb` altında kaydet.
- [x] **Adım 6:** `ATTRIBUTION.md` ve ilgili mimari dokümanları güncelle.
- [x] **Adım 7:** Test süitini yaz ve tüm kontrolleri (Minitest, RuboCop, GitNexus detect_changes) tamamla.

---

## ✅ Uygulama Sonucu ve Deviation Log

> **Durum:** Uygulandı (plan 84, `feat: implement Plan 84` commit'i ile)
> **Doğrulama:** 7 adımın tümü kod tabanında doğrulandı; `rake test` hattı yeşil

### Doğrulama (adım → kod karşılığı)

| Adım | Kod karşılığı | Durum |
|:--|:--|:--|
| 1 | `lib/rubik/mcp/transport/stdio.rb`, `lib/rubik/mcp/client.rb` | ✅ |
| 2 | `lib/rubik/mcp/proxy_tool.rb` | ✅ |
| 3 | `lib/rubik/mcp/manager.rb` | ✅ |
| 4 | `defaults.rb:73` `"mcp" => { "enabled" => true, "servers" => {} }` | ✅ |
| 5 | `lib/rubik/repl/commands/mcp.rb` (`register_command("mcp", ...)`) | ✅ |
| 6 | `ATTRIBUTION.md` MCP bölümü | ✅ |
| 7 | `test_mcp_client.rb`, `test_mcp_manager_composability.rb`, `test_mcp_proxy_tool.rb`, `test_repl_mcp_command.rb` | ✅ |

### Kayıtlı Deviation

1. **Uygulama Adımları checkbox'ları plan dosyasında işaretlenmemişti** — bu log, uygulamanın yapıldığını ve kodda doğrulandığını kaydeder. Kod tarafında sapma yok.
2. **`mcp` varsayılanı** cut-and-dry `{ "enabled" => true, "servers" => {} }`; aktif sunucular runtime'da tanımlanır (statik config değil).
