# Plan: Doğrulanmış HIGH Bulgu Düzeltmeleri — 2026-09-24

Yaklaşım: **Clean-architecture** (kullanıcı seçimi), W11 decoupling düzeltmesiyle.
Kaynak: 3 code-architect blueprint; verify raporu (11 HIGH + H8 + H12; H1 hariç).

## Bağlayıcı kararlar (kullanıcı onaylı)
- Symlink: realpath YALNIZ güvenlik sınırında (Buffer::Manager); normalize_path_raw/anahtarlar lexical kalır.
- Güvenlik: artımlı (denylist yapısı korunur; allowlist redesign yok).
- H5: drain'i TAMAMLA → İLK Interrupt/SystemExit'i re-raise et (`rescue Exception` yok).
- Kapsam: H2,H3,H4,H5,H6,H8,H9,H10,H11,H12,H13,H14,H15.

## İş kalemleri
- **W1 (H2)** `sandbox/driver.rb`: register snapshot-prior alır; dispose inverse'i `.equal?` korumasıyla prior'u restore eder (yoksa siler).
- **W2 (H3)** `platform/path.rb` + `buffer/manager.rb`: `Platform.resolved_path` (en derin VAR atanı + lexical tail; SystemCallError→lexical fallback) ve `resolved_path_under?` seam'i; sanitize_path iki find çağrısında kullanır. Saklanan anahtarlar lexical.
- **W3 (H4)** `buffer/manager.rb`: private `containment_root` (sanitize+apply tek kaynak); apply! atomic_write öncesi re-verify → **raise** InvalidPathError + `:buffer_containment_blocked` event; entry dirty kalır.
- **W4 (H5)** `runtime/context.rb`: dispose drain döngüsünde + child-dispose döngüsünde `rescue Interrupt, SystemExit`; `record_deferred_signal` (last_dispose_errors + warn); drain + bookkeeping + prune_child bittikten sonra İLK sinyal re-raise. register_disposable'ın sealed immediate-run yolu Interrupt'ı direkt bırakır.
- **W5 (H6)** YENİ `platform/io_drain.rb`: `Platform::IoDrain` (kill+join(0.5) lifecycle, on_line opsiyonel). LSP client: popen3 sonrası start, stop'ta stop. MCP stdio dokunulmaz (backlog).
- **W6 (H8)** `tools/preflight_runner.rb`: `guard:` ZORUNLU kwarg; spawn öncesi verify (respond_to? duck-type); `rescue BlockedWriteError → "security verification failed: ..."` String dön (run kontratı: nil|String|:spawn_failed). synthesis.rb 88+250 `guard: @guard` geçirir. Tüm test çağıranları güncellenir.
- **W7 (H9)** `security/guard.rb` FORBIDDEN_SYNTHESIS_CONSTS += ENV, ObjectSpace, STDIN, STDOUT, STDERR, ARGF, Signal (intent-comment gruplu; GC/ARGV/Fiber bilinçli hariç).
- **W8 (H10+H11)** guard.rb:31 → adlı sabit `PIPE_TO_INTERPRETER_PATTERN` + un-allowlistable blast-radius yorumu. Kaynak grubuna `\b`; intermediaries flag-less (sudo|doas|env|nohup|nice|stdbuf|xargs)+; interpreter set +bash,zsh,dash,ksh,sh,pwsh,python\d?,ruby,perl,node,php,lua; trailing `\b`. (minimal'in `\b(?:curl|wget)\b` ön-boundary ödüncü.)
- **W9 (H12)** classifier: `CommandInvocation#assignments` alanı (Data); bash_extractors pre-command assignment'ları argv dışında toplar; Engine `apply_assignment_payloads` — değer Parser.parse → `Delegation.match_inner_command(delegation_mode: "env_assignment")` → max-severity elevation + reason "elevated by env assignment payload"; `command_shaped?` firewall (DB-bilinen binary veya path-benzeri; `-` başlayan token hariç). `FOO=$(rm -rf /) cmd` aynı yolla kapanır. LANG=C sort değişmez.
- **W10 (H13)** `repl/tee_io.rb`: `ordered_targets` (user'lar önce, recorder'lar sonra), `drop_failed_target` (bir kez warn + hedefi ayır), dispatch per-target rescue; flush per-target.
- **W11 (H14)** 3× LOKAL (test_repl_command_decoupling nedeniyle konsolidasyon YOK): presentation.rb (Dir.pwd-relative), git_info.rb (private git_dir helper; git_repo?/active_branch rewiring), repo_context_reader.rb — `.git` FILE ise `gitdir: <path>` → `<path>/HEAD`; relative gitdir root'a göre expand.
- **W12 (H15)** provider_recovery.rb:28: `/context_length|context window|maximum context|prompt is too long|token limit|too many tokens/i` + bare-context-yasak yorumu.

## Commit planı (conventional, review sonrası github:commit ile)
1. fix(sandbox) W1 · 2. fix(runtime) W4 · 3. fix(buffer) W2 · 4. fix(buffer) W3 · 5. fix(lsp)+platform W5 · 6. fix(tools) W6 · 7. fix(security) W7 · 8. fix(security) W8 · 9. fix(classifier) W9 · 10. fix(repl) W10 · 11. fix(context) W11 · 12. fix(orchestrator) W12

## Test haritası
W1→test_sandbox_drivers.rb; W2→test_path_containment.rb(yeni)+test_write_file_path_validation.rb; W3→test_write_file_path_validation.rb; W4→test_context_dispose_hygiene.rb+test_runtime_context.rb; W5→test_platform_io_drain.rb(yeni)+test_lsp_client.rb; W6→test_preflight_runner.rb; W7/W8→test_security_guard_synthesis.rb+test_security_guard_classifier.rb+test_security_guard.rb; W9→test_command_classifier_bash_parser.rb+test_security_guard_classifier.rb; W10→tee testleri; W11→test_git_info.rb+test_repo_context_reader.rb+test_repl_presentation_git_branch.rb(yeni); W12→test_provider_recovery.rb.

## Uygulama sırası
W12 → W1 → W4 → W2 → W3 → W7 → W8 → W6 → W9 (en geniş, en son) → W5 → W10 → W11 → tam suite + GitNexus detect-changes (her commit öncesi).

## Kritik tuzaklar (blueprint'lerden)
- W6: BlockedWriteError rescue'suz kalırsa :spawn_failed'a düşer → in-process fallback bloklanan kodu ÇALIŞTIRIR.
- W9 "argv'de tut" seçeneği ÇÜRÜTÜLDÜ (UNKNOWN guard'ı geçmez) — değer-sibling tasarımı şart.
- W2 naive realpath ENOENT'ta yeni-dosya deliğini bırakır — deepest-existing-ancestor şart.
- W11: presentation Context::GitInfo require EDEMEZ (decoupling testi).
- Her sembol öncesi GitNexus impact (UNKNOWN → text-search doğrulaması explorer haritalarıyla yapıldı).
