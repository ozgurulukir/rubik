# Fix 8 Test Failures on Windows (Ruby 4.0.6)

## Goal

Make the rubik test suite green on Windows (Ruby 4.0.6 x64-mingw-ucrt) by applying the targeted fixes whose root causes have already been fully investigated by debugger agents. This plan implements those findings only — no re-investigation, no scope creep. After the fixes, the 8 previously-failing tests pass individually and the full suite reports **0 failures** (the 12 pre-existing skips are acceptable).

**Note on the count:** the investigation's "8 fixes" is really **7 fixes + 1 hardening**. Six changes (A1, A2, B1, B2, B3, C1) fix the 8 failing tests; **A3 is latent-bug hardening that fixes no failing test** (it corrects audit reasons for nested dangerous commands). The 8 = the number of failing tests, not the number of source changes.

The changes fall into three clusters:

- **Cluster A — Security / command classifier** (3 source fixes + 1 latent hardening): `classifier.rb`, `parser.rb`, `guard.rb`.
- **Cluster B — Platform / native-search / discovery** (3 fixes, 1 test + 2 source): `test_platform.rb`, `native_search.rb`, `discovery.rb`.
- **Cluster C — Node adapter** (1 TEST fix): `test_lsp_jit_buffer_sync_and_web_adapter.rb`.

## Steps

### Cluster A — Security / command classifier

#### A1. `lib/rubik/security/classifier/classifier.rb` — `system_path?` POSIX-only matching

**Why:** `SYSTEM_DIRS` (lines 12-15) is a POSIX-only literal (`/etc`, `/usr`, …). Line 251 checks `norm == sys || norm.start_with?("#{sys}/")`. On Windows, redirect targets like `/etc/shadow` normalize to `c:/etc/shadow` and never match the `/etc` prefix, so system-path writes are not flagged.

**Change (line 251):**

```ruby
# BEFORE
return true if SYSTEM_DIRS.any? { |sys| norm == sys || norm.start_with?("#{sys}/") }

# AFTER
return true if SYSTEM_DIRS.any? { |sys| Rubik::Platform.path_under?(norm, sys) }
```

`Rubik::Platform.path_under?(child, parent)` (`lib/rubik/platform/path.rb:105`) normalizes both sides internally (downcases on Windows) and returns true for `child == parent || child.start_with?("#{parent}/")` — exactly the semantics of the old check, but platform-aware. On Linux/macOS `normalize_path` is identity (no downcase), so behavior is unchanged.

**Optional (recommended) micro-optimization:** pre-normalize the system dirs once in a class-level cache so `path_under?` doesn't re-normalize `sys` on every call:

```ruby
# class body, near SYSTEM_DIRS
SYSTEM_DIRS_NORM = SYSTEM_DIRS.map { |sys| Rubik::Platform.normalize_path(sys) }.freeze

# line 251
return true if SYSTEM_DIRS_NORM.any? { |sys| Rubik::Platform.path_under?(norm, sys) }
```

**Fixes tests:** `test_blocks_real_dangerous_commands_via_ast` (4th cmd), `test_path_traversal_detection` (3rd cmd), `test_detects_system_path_write_redirect`.

---

#### A2. `lib/rubik/security/classifier/parser.rb` — PowerShell default on Windows

**Why:** `Parser.parse` (lines 11-20) defaults to the PowerShell parser when `shell.nil? && Rubik::Platform.windows?` (line 13). The PowerShell parser does not treat `&` as a background marker, so `test_background_command_elevation` classifies the command as `:readonly` instead of `:local_effects`.

**Change (lines 12-13):**

```ruby
# BEFORE
is_pwsh = (shell.to_s.downcase == "powershell" || shell == :pwsh || shell == :powershell) ||
          (shell.nil? && Rubik::Platform.windows?)

# AFTER
is_pwsh = (shell.to_s.downcase == "powershell" || shell == :pwsh || shell == :powershell)
```

Shell-specific parsing stays opt-in via the `shell:` keyword. `test_blocks_powershell_dangerous_commands` passes `shell: :powershell` explicitly, so it is unaffected.

**Fixes test:** `test_background_command_elevation`.

---

#### A3. `lib/rubik/security/guard.rb` — `dangerous_reason` NoMethodError on inner commands

**Why:** `dangerous_reason` (lines 151-159) recurses into `c.inner_commands` and calls `c.classification_reason` on `InnerCommandResult`, which lacks that field → `NoMethodError`, swallowed by the broad `rescue StandardError` at line 144. This is a latent regression from commit `acfbfca`; fixing it makes audit reasons correct for `sudo X` / `sh -c X`.

**Change (line 156):**

```ruby
# BEFORE
return inner || c.classification_reason || "dangerous_command"

# AFTER
return inner || (c.respond_to?(:classification_reason) && c.classification_reason) || "dangerous_command"
```

**Optional hardening:** narrow the broad `rescue StandardError` at line 144 to `rescue NoMethodError, ArgumentError` (or log the exception class) so future regressions surface instead of being silently swallowed. Keep the `rescue BlockedWriteError; raise` at 142-143.

**Fixes:** latent bug; no single failing test, but corrects audit reasons for nested dangerous commands (`sudo X`, `sh -c X`).

---

### Cluster B — Platform / native-search / discovery

#### B1. `test/unit/test_platform.rb:319` — TEST fix (not source)

**Why:** `normalize_path_raw("/foo/bar")` returns `C:/foo/bar` on Windows (correct OS behavior; all production callers want the drive form). The test asserts the POSIX form unconditionally.

**Change (line 319):** wrap in a platform branch, mirroring the existing pattern in `test_to_file_uri_and_from_file_uri` (lines 114-134) and `test_path_normalization_and_comparison` (lines 136-148). Lines 315/317 already work on both platforms and stay untouched.

```ruby
# BEFORE
assert_equal "/foo/bar", Rubik::Platform.normalize_path_raw("/foo/bar")

# AFTER
if Rubik::Platform.windows?
  assert_equal "C:/foo/bar", Rubik::Platform.normalize_path_raw("/foo/bar")
else
  assert_equal "/foo/bar", Rubik::Platform.normalize_path_raw("/foo/bar")
end
```

**Fixes test:** `test_normalize_path_raw`.

---

#### B2. `lib/rubik/tools/native_search.rb:80` — `runner:` injection hook ignored

**Why:** `search` returns `nil unless rg` (line 80), which ignores the `runner:` injection hook used by tests. An injected runner should bypass the rg-binary check.

**Change (line 80):**

```ruby
# BEFORE
return nil unless rg

# AFTER
return nil if rg.nil? && runner.nil?
```

**Verify:** `run_spawn` (lines 144-148) already returns early when `runner` is set, so a nil `argv[0]` is harmless in the injected-runner path.

**Fixes test:** the native-search test that injects a `runner:` (previously failing because the injected runner was bypassed).

---

#### B3. `lib/rubik/runtime/discovery.rb:187` — Windows executable check

**Why:** `binary_available?` checks `File.file?(full_path) && File.executable?(full_path)`. On Windows `File.executable?` is unreliable; `Rubik::Platform.executable_file?` (`lib/rubik/platform/path.rb:59`) already checks `File.file?` internally and handles Windows.

**Change (line 187):**

```ruby
# BEFORE
return true if File.file?(full_path) && File.executable?(full_path)

# AFTER
return true if Rubik::Platform.executable_file?(full_path)
```

**Fixes test:** the discovery test that asserts a local binary is available on Windows.

---

### Cluster C — Node adapter

#### C1. `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb:111-135` — TEST fix (not source)

**Why (empirically validated by review):** `test_node_adapter_check_syntax_command_generation` fails at line 131 (`Expected: 3, Actual: 2`) because, under the test PATH (which excludes node tools), none of tsc/vue-tsc/npx are available. The `.vue` branch (node.rb:65-72) returns `unavailable_result` when neither `vue-tsc` nor `npx` is available, so `ProcessRunner.run` is never called for the `.vue` file → only 2 commands recorded. **Crucially, the `.ts` branch ALSO falls through to `node --check`** (not `tsc --noEmit`) under the same PATH, so a source-side fix that only restores the command *count* would still fail the *content* assertions at lines 132-134. The correct fix is test-side: stub `binary_available?` so the current source yields `tsc --noEmit`, `vue-tsc --noEmit`, `node --check`.

**Change (lines 124-128):** wrap the three `check_syntax` calls in a `Rubik::Runtime::Discovery.stub(:binary_available?, true)` block, alongside the existing `adapter.stub(:available?, true)`.

```ruby
# BEFORE
adapter.stub(:available?, true) do
  adapter.check_syntax(ts_file)
  adapter.check_syntax(vue_file)
  adapter.check_syntax(js_file)
end

# AFTER
Rubik::Runtime::Discovery.stub(:binary_available?, true) do
  adapter.stub(:available?, true) do
    adapter.check_syntax(ts_file)
    adapter.check_syntax(vue_file)
    adapter.check_syntax(js_file)
  end
end
```

With that stub, the **unmodified** current source already yields `tsc --noEmit`, `vue-tsc --noEmit`, `node --check` → 3 commands, all assertions green.

**Latent improvement (NOT what fixes the test):** the `.vue` branch (node.rb:65-72) omits the `#{escaped}` file argument on the `vue-tsc`/`npx` commands, unlike the `.ts` branch. Adding `#{escaped}` there is a consistency improvement only — it does not affect this test's pass/fail and is out of scope for this fix. Do not change `lib/rubik/adapter/node.rb` as part of C1.

**Fixes test:** `test_node_adapter_check_syntax_command_generation`.

---

## Verification

1. **Run each of the 8 previously-failing tests individually** and confirm green. Use the pinned bundler and the single-test invocation pattern:

   ```
   ridk exec bash -lc 'export PATH="/c/Ruby40-x64/bin:/c/Users/ozgur/scoop/apps/rustup/current/.cargo/bin:$PATH"; cd /c/Github/rubik; bundle _4.0.16_ exec ruby -Itest <file> -n <test>'
   ```

   Tests to confirm (file → test name):
   - `test/unit/test_security_guard_classifier.rb` → `test_blocks_real_dangerous_commands_via_ast`, `test_path_traversal_detection`
   - `test/unit/test_command_classifier_integration.rb` → `test_detects_system_path_write_redirect`, `test_background_command_elevation`
   - `test/unit/test_platform.rb` → `test_normalize_path_raw`
   - `test/unit/test_native_search.rb` → `test_runner_injection_and_explicit_path_stdin_guard`
   - `test/unit/test_runtime_discovery.rb` → `test_discover_test_runners_filters_available_binaries`
   - `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb` → `test_node_adapter_check_syntax_command_generation`

2. **Run the full suite** and report the new failure count:

   ```
   ridk exec bash -lc 'export PATH="/c/Ruby40-x64/bin:/c/Users/ozgur/scoop/apps/rustup/current/.cargo/bin:$PATH"; cd /c/Github/rubik; bundle _4.0.16_ exec rake test'
   ```

   Expect **0 failures**; the 12 pre-existing skips are fine.

3. **Run-time & output capture:** the full suite takes ~12 minutes. `ridk exec` output capture is flaky — use a **script-file + exit-marker pattern** (write the test run into a `.sh` script, run it via `ridk exec bash -lc`, and echo a sentinel exit marker at the end) rather than relying on inline stdout capture.

4. **Do NOT touch** the tree_sitter env vars, the bundler pin (4.0.16), or the fiddle work already done. Only the fixes listed above.

5. **After the fixes, run `git diff`** to confirm only the intended files changed:
   - `lib/rubik/security/classifier/classifier.rb`
   - `lib/rubik/security/classifier/parser.rb`
   - `lib/rubik/security/guard.rb`
   - `test/unit/test_platform.rb`
   - `lib/rubik/tools/native_search.rb`
   - `lib/rubik/runtime/discovery.rb`
   - `test/unit/test_lsp_jit_buffer_sync_and_web_adapter.rb`

## Architecture Decisions

- **Platform-aware path matching (A1):** Reuse the existing `Rubik::Platform.path_under?` abstraction instead of adding Windows-specific branches inline. Rationale: it already encapsulates the normalize-and-compare semantics and is exercised by existing tests (`test_path_normalization_and_comparison`). Alternative (adding `c:/etc` etc. to `SYSTEM_DIRS`) was rejected because it duplicates the logic already in `dangerous_system_roots` and would drift. Trade-off: `path_under?` normalizes on every call; mitigated by the optional class-level `SYSTEM_DIRS_NORM` cache.
- **Bash default parser (A2):** Make shell-specific parsing strictly opt-in via `shell:`. Rationale: the classifier's bash grammar is the canonical one; PowerShell parsing should only apply when explicitly requested. Trade-off: on Windows, unqualified commands are now parsed as bash — this is the intended behavior and matches the test contract.
- **Guard against missing fields (A3):** Use `respond_to?` rather than changing `InnerCommandResult` to add `classification_reason`. Rationale: minimal, non-invasive; avoids touching the model layer. Optionally narrow the broad rescue so future regressions are loud.
- **Injected-runner bypass (B2):** `return nil if rg.nil? && runner.nil?` keeps the safety fallback for real (non-injected) calls while honoring the test injection hook. Verified `run_spawn` short-circuits when `runner` is set.
- **Test-side stub for binary availability (C1):** Stub `Rubik::Runtime::Discovery.binary_available?` in the test so the **unmodified** current source's environment-dependent branches deterministically pick `tsc --noEmit`, `vue-tsc --noEmit`, `node --check`. Rationale (empirically validated by review): under the test runner's PATH none of tsc/vue-tsc/npx are available, so without the stub the `.ts` branch falls through to `node --check` and the `.vue` branch returns early — the failing assertions are about command *content*, not just count. A source-side fix to the `.vue` branch alone restores the count (3) but still fails at the `tsc --noEmit` content assertion. Note: the `.vue` branch omitting `#{escaped}` on its `vue-tsc`/`npx` commands is a latent consistency improvement, explicit out of scope for this fix — it is NOT what makes the test pass. `Rubik::Runtime::Discovery.stub(:binary_available?, true)` is an established pattern in this repo (e.g. `test/unit/test_adapter_base_format_code.rb`, `test/unit/test_crystal_and_generic_adapter.rb`, `test/unit/test_discovery_test_runner.rb`), so it follows existing conventions.

## Open Questions

- **A1 cache:** Whether to add the `SYSTEM_DIRS_NORM` class-level cache now or keep the one-line `path_under?` swap. The cache is a pure optimization; the one-liner is sufficient to fix the tests. Default: apply the one-liner; add the cache only if a reviewer prefers it.
- **A3 rescue narrowing:** Whether to narrow the broad `rescue StandardError` at `guard.rb:144`. Recommended but optional; it changes error-handling behavior beyond the minimal fix. Default: apply the `respond_to?` guard; leave the rescue as-is unless a reviewer requests narrowing.
