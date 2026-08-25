# Plan: Add Tests for Result#to_s and Config#fetch

## Source Files
- `lib/rubik/tools/result.rb` — `Result#to_s` (line 28-30) returns `@output`; `Result#to_xml` (line 32-43) generates XML format
- `lib/rubik/config.rb` — `Config#fetch` (line 163-169) splits key by dots, walks `@data` hash, returns default if not found

## Existing Test Files
- `test/unit/test_expanded_tools.rb` — Tests for tools (ListFiles, SearchSymbols, RunCommand, Registry). Uses Minitest, `setup`/`teardown` with temp dirs.
- `test/unit/test_config.rb` — Tests for Config (defaults, overrides, corrupted YAML, unknown keys, persistence). Uses Minitest, `setup`/`teardown` with temp dirs.

## Test Plan

### 1. Result#to_s tests (add to test/unit/test_expanded_tools.rb)
- `test_result_to_s_basic` — Basic output format
- `test_result_to_s_with_error` — With error status
- `test_result_to_s_with_truncated` — With truncated flag
- `test_result_to_s_with_duration` — With duration_ms
- `test_result_to_xml` — XML format output

### 2. Config#fetch tests (add to test/unit/test_config.rb)
- `test_fetch_existing_key` — Fetching existing key
- `test_fetch_non_existent_key` — Fetching non-existent key (returns nil)
- `test_fetch_with_default` — Fetching with default value
- `test_fetch_nested_key` — Nested key access (dot notation)