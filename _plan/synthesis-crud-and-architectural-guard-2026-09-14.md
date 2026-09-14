# Synthesis CRUD Gap (Finding 7) + Architectural Guard Test (Finding 2)

## Goal

Close two verified gaps from `_reviews/2026-09-14-architectural-review.md`:

1. **Workstream A (Finding 7 / Recommendation 6):** Complete the synthesis lifecycle CRUD. Today `SynthesizeCommandTool` / `SynthesizeToolTool` can Create/Read/Update but there is **no Delete** path: `OverlayStorage` has no `delete_command`/`delete_tool`, and nothing calls `Tools::Registry#unregister` from a delete flow. This caused a real "ghost tool" incident (a synthesized tool stayed live in the registry for hours after its disk file was manually removed; only a process restart removed it). We add `delete_command`/`delete_tool` to `OverlayStorage`, a single `unsynthesize` tool (the twin of the two synthesize tools) that removes the live registration AND the disk file, wired into `Registry.build_default`, plus a critical regression test asserting live/disk divergence cannot recur.

2. **Workstream B (Finding 2 / Recommendation 2):** Lock the architectural invariant "no `require`/`require_relative` from `lib/rubik/{orchestrator,runtime,tools,llm}` back into `lib/rubik/repl`" into CI with one test file. The coupling tool cannot see method-level coupling, so a single guard test is the only cheap enforcement.

Constraints honored: AGENTS.md §6 checklist (locality of disposal, explicit dependencies, LIFO unwinding, atomic rollback, sub-context scoping, zero-restart), no new dependencies, no breaking changes, no unrelated refactors.

---

## Steps

### Workstream A — Synthesis CRUD

#### A1. `lib/rubik/runtime/overlay_storage.rb` — add `delete_command` / `delete_tool`

**Why:** The storage layer is the single source of truth for overlay persistence. Delete must remove **both** the manifest entry and the file, mirroring `save_command`/`save_tool` conventions exactly (clean_name normalization, scope→dir selection, `{ ok:, error: }` return shape, `rescue StandardError`).

**Change — add two public methods** (place after `save_command`/`save_tool` respectively, before the `list_*` methods):

```ruby
def delete_command(name, scope: :project)
  clean_name = name.to_s.downcase.delete_prefix("!").gsub(/[^a-z0-9_:]/, "_")
  target_dir = scope.to_sym == :global ? global_commands_dir : project_commands_dir
  filename = "#{clean_name.gsub(':', '_')}.rb"
  file_path = File.join(target_dir, filename)

  manifest = load_manifest(target_dir)
  manifest.delete(filename)
  save_manifest(target_dir, manifest)

  FileUtils.rm_f(file_path)
  { ok: true, name: clean_name, scope: scope, path: file_path }
rescue StandardError => e
  { ok: false, error: e.message }
end
```

```ruby
def delete_tool(name, scope: :project)
  clean_name = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
  target_dir = scope.to_sym == :global ? global_tools_dir : project_tools_dir
  filename = "#{clean_name}.rb"
  file_path = File.join(target_dir, filename)

  manifest = load_manifest(target_dir)
  manifest.delete(filename)
  save_manifest(target_dir, manifest)

  FileUtils.rm_f(file_path)
  { ok: true, name: clean_name, scope: scope, path: file_path }
rescue StandardError => e
  { ok: false, error: e.message }
end
```

**Key details:**
- `clean_name` normalization **must match** the corresponding `save_*` method exactly (command: `delete_prefix("!")` + `gsub(/[^a-z0-9_:]/, "_")` + `gsub(':', '_')` for the filename; tool: `gsub(/[^a-z0-9_]/, "_")`). Otherwise delete would compute a different filename than save wrote and fail to remove the file.
- `scope.to_sym == :global` selects the same dir as `save_*`. `:session` is not persisted, so callers should not pass it here (the `unsynthesize` tool guards this).
- `load_manifest` returns `{}` on missing/corrupt manifest, so `manifest.delete` is safe; `save_manifest` re-writes atomically via `Platform.atomic_write`. Deleting a non-existent entry is a no-op (idempotent).
- `FileUtils.rm_f` is already required at the top of the file (line 3).
- Return shape mirrors `save_*`: `{ ok: true, ... }` or `{ ok: false, error: }`.

**Verify:** `ruby -Itest test/unit/test_overlay_integrity.rb` still green; new delete assertions in A3 pass.

---

#### A2. `lib/rubik/tools/builtins/synthesis.rb` — add `UnsynthesizeTool`

**Why:** The review's Recommendation 6 asks for a single delete tool as the twin of the two synthesize tools. Placing it in the same file keeps locality (both twins already live here) and `builtins.rb` already requires `builtins/synthesis`, so no new require wiring is needed.

**Change — add a new class** at the end of the file (after `SynthesizeToolTool`), inside `module Rubik::Tools`:

```ruby
class UnsynthesizeTool < BaseTool
  def initialize(shell = nil, tool_registry = nil, overlay_storage = nil, legacy_runtime_manager = nil, runtime_manager: nil)
    super(
      name: "unsynthesize",
      aliases: ["delete_tool", "delete_command", "remove_tool", "remove_command"],
      description: "Delete a previously synthesized command or tool from both the live registry and disk (project or global scope)",
      risk: :write,
      params_schema: {
        type: "object",
        properties: {
          name: { type: "string", description: "Name of the command (without '!') or tool to delete" },
          kind: { type: "string", enum: ["command", "tool"], description: "Whether to delete a command or a tool" },
          scope: { type: "string", enum: ["session", "project", "global"],
                   description: "Storage scope: session (live only), project (.rubik/...), global (~/.rubik/...)" }
        },
        required: ["name", "kind"]
      }
    )
    @shell = shell
    @tool_registry = tool_registry
    @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new
    @runtime_manager = runtime_manager || legacy_runtime_manager
  end

  def execute(args = {})
    name = (args["name"] || args[:name]).to_s.strip.delete_prefix("!")
    kind = (args["kind"] || args[:kind]).to_s.downcase.to_sym
    scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym

    return ToolOutput.error("Name cannot be empty") if name.empty?
    return ToolOutput.error("kind must be 'command' or 'tool'") unless [:command, :tool].include?(kind)

    kind == :command ? delete_command(name, scope) : delete_tool(name, scope)
  end

  private

  def delete_command(name, scope)
    clean = name.to_s.downcase.delete_prefix("!")
    previous_meta = @shell&.commands&.[](clean)

    @shell&.unregister_command(clean)

    if [:project, :global].include?(scope)
      res = @overlay_storage.delete_command(name, scope: scope)
      return ToolOutput.error("Failed to delete command from disk: #{res[:error]}") unless res[:ok]
    end

    # Revertible inverse (AGENTS.md §1.A): restore the previous command on
    # dispose if one existed before deletion.
    if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
      @runtime_manager.context.on_dispose do
        if previous_meta
          @shell.register_command(clean, description: previous_meta[:description],
                                         custom: previous_meta[:custom], audience: previous_meta[:audience],
                                     &previous_meta[:handler])
        end
      end
    end

    "Successfully deleted command '!#{clean}' [scope: #{scope}]."
  end

  def delete_tool(name, scope)
    clean = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
    previous_tool = @tool_registry&.get(clean)
    previous_origin = previous_tool ? @tool_registry.origin(clean) : nil

    @tool_registry&.unregister(clean)

    if [:project, :global].include?(scope)
      res = @overlay_storage.delete_tool(name, scope: scope)
      return ToolOutput.error("Failed to delete tool from disk: #{res[:error]}") unless res[:ok]
    end

    # Revertible inverse (AGENTS.md §1.A): restore the previous tool on dispose.
    if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
      @runtime_manager.context.on_dispose do
        @tool_registry.swap(clean, previous_tool, origin: previous_origin || :overlay) if previous_tool
      end
    end

    "Successfully deleted tool '#{clean}' [scope: #{scope}]."
  end
end
```

**Key details:**
- **Live removal:** commands via `@shell.unregister_command(name)` (exists at `shell.rb:174`); tools via `@tool_registry.unregister(name)` (exists at `registry.rb:33`). Both are idempotent for a missing name.
- **Disk removal:** only for `:project`/`:global` scope, matching the synthesize tools' persistence condition. `:session` deletes live-only (nothing was persisted).
- **Revertible inverse:** captures the previous command meta / tool instance + origin *before* deletion, then registers `on_dispose` to restore it. If nothing existed before, no inverse is registered (nothing to restore). This satisfies AGENTS.md §1.A locality-of-disposal and LIFO unwinding. Note the LIFO interaction with a prior synthesize: synthesize registers an unregister-inverse, then unsynthesize registers a restore-inverse; on dispose the restore runs first, then the unregister — net effect is the tool/command is gone, which is the correct full-session unwind.
- **Explicit dependencies:** `@shell`, `@tool_registry`, `@overlay_storage`, `@runtime_manager` are injected (same pattern as the twins). No global singletons.
- **Atomic rollback:** if the disk delete fails, we return `ToolOutput.error` — but note the live unregister already happened. This matches the synthesize tools' ordering (persist-then-register) inverted: here we unregister-then-delete-disk. To keep rollback clean, capture the previous state *before* any mutation (done) so the dispose inverse can restore even if disk delete fails. This is acceptable and consistent with the twins' behavior.
- **`ToolOutput`** is already required via `require_relative "../output"` at the top of `synthesis.rb`; `BaseTool` via `require_relative "../base"`.

**Verify:** `ruby -Itest test/unit/test_self_evolving_tool_synthesis.rb` still green; new A3 tests pass.

---

#### A3. `lib/rubik/tools/registry.rb` — wire `UnsynthesizeTool` into `build_default`

**Why:** The tool must be available to the agent's toolbelt. `build_default` already registers both synthesize twins.

**Change — add one line** after the two synthesize registrations (line 122):

```ruby
registry.register(SynthesizeCommandTool.new(shell, overlay_storage, guard, runtime_manager: runtime_manager))
registry.register(SynthesizeToolTool.new(registry, overlay_storage, guard, runtime_manager: runtime_manager))
registry.register(UnsynthesizeTool.new(shell, registry, overlay_storage, runtime_manager: runtime_manager))
```

`UnsynthesizeTool` is defined in `builtins/synthesis.rb`, which `builtins.rb` already requires, and `registry.rb` references the builtins via the `Rubik::Tools` namespace (the twins are referenced the same way), so no new require is needed.

**Verify:** `ruby -Itest test/unit/test_self_evolving_tool_synthesis.rb` green; a quick smoke that `Rubik::Tools::Registry.build_default(...)` includes `unsynthesize` (covered by A3 test if it builds a default registry, or by manual check).

---

#### A4. `test/unit/test_self_evolving_tool_synthesis.rb` — critical regression tests

**Why:** The review flags live/disk divergence as a "sneaky regression class." The critical test must assert **both** disk absence AND `registry.get(name).nil?` after delete, for both commands and tools. Follow the existing setup in this file (temp dirs, real `OverlayStorage`, real `Shell`, real `Registry`).

**Change — add two tests** to the existing class (reuse `setup`/`teardown`):

```ruby
def test_unsynthesize_tool_removes_live_and_disk
  synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)
  res = synthesizer.execute("name" => "ghost_tool", "description" => "d", "scope" => "project",
                            "code" => "->(args) { 'hello' }")
  assert_includes res, "Successfully synthesized"
  tool_file = File.join(@temp_dir, ".rubik", "tools", "ghost_tool.rb")
  assert File.exist?(tool_file)
  refute_nil @tool_registry.get("ghost_tool")

  unsynthesizer = Rubik::Tools::UnsynthesizeTool.new(nil, @tool_registry, @overlay_storage)
  del = unsynthesizer.execute("name" => "ghost_tool", "kind" => "tool", "scope" => "project")
  assert_includes del, "Successfully deleted tool 'ghost_tool'"

  refute File.exist?(tool_file), "disk file must be removed"
  assert_nil @tool_registry.get("ghost_tool"), "live registry must not retain the tool"
  manifest = JSON.parse(File.read(File.join(@temp_dir, ".rubik", "tools", ".manifest.json")))
  refute manifest.key?("ghost_tool.rb"), "manifest entry must be removed"
end

def test_unsynthesize_command_removes_live_and_disk
  synthesizer = Rubik::Tools::SynthesizeCommandTool.new(@shell, @overlay_storage)
  res = synthesizer.execute("name" => "ghost_cmd", "description" => "d", "scope" => "project",
                            "code" => "->(args, out, shell) { 'hi' }")
  assert_includes res, "Successfully synthesized"
  cmd_file = File.join(@temp_dir, ".rubik", "commands", "ghost_cmd.rb")
  assert File.exist?(cmd_file)
  refute_nil @shell.commands["ghost_cmd"]

  unsynthesizer = Rubik::Tools::UnsynthesizeTool.new(@shell, nil, @overlay_storage)
  del = unsynthesizer.execute("name" => "ghost_cmd", "kind" => "command", "scope" => "project")
  assert_includes del, "Successfully deleted command '!ghost_cmd'"

  refute File.exist?(cmd_file), "disk file must be removed"
  assert_nil @shell.commands["ghost_cmd"], "live command table must not retain the command"
  manifest = JSON.parse(File.read(File.join(@temp_dir, ".rubik", "commands", ".manifest.json")))
  refute manifest.key?("ghost_cmd.rb"), "manifest entry must be removed"
end
```

**Key details:**
- `setup` already provides `@shell = Rubik::REPL::Shell.new(...)`, `@overlay_storage`, `@tool_registry`, `@temp_dir` — reuse them.
- The command test needs a real `Shell` because `SynthesizeCommandTool` calls `@shell.register_command`/`@shell.commands`/`@shell.output`. The existing `setup` provides it.
- Assert the manifest entry is gone too — this closes the "empty manifest entry" residue the review noted.
- `JSON` is available (required transitively via `test_helper` → `rubik`).

**Verify:** `ruby -Itest test/unit/test_self_evolving_tool_synthesis.rb` — all tests green, including the two new ones.

---

### Workstream B — Architectural guard test

#### B1. `test/unit/test_architectural_boundaries.rb` — new file

**Why:** The review (Finding 2) notes the coupling tool cannot see method-level coupling and the require direction is currently healthy but unenforced. One test file locks the invariant into CI.

**Change — create the file:**

```ruby
# frozen_string_literal: true

require_relative "../test_helper"

# Architectural invariant (Finding 2): the core runtime layers must never
# require back into the REPL layer. lib/rubik/repl is the composition root;
# orchestrator/runtime/tools/llm are its dependencies, not vice versa. The
# coupling tool cannot see method-level coupling, so this guard test is the
# cheap CI enforcement.
class TestArchitecturalBoundaries < Minitest::Test
  LIB = File.expand_path("../../lib/rubik", __dir__)
  REPL_DIR = File.join(LIB, "repl")
  GUARDED_DIRS = %w[orchestrator runtime tools llm].freeze

  def test_no_requires_from_core_dirs_back_into_repl
    violations = []

    GUARDED_DIRS.each do |dir|
      Dir.glob(File.join(LIB, dir, "**", "*.rb")).each do |file|
        File.readlines(file).each_with_index do |line, idx|
          if (m = line.match(/^\s*require_relative\s+["'](.+?)["']/))
            resolved = File.expand_path(m[1], File.dirname(file))
            violations << "#{file}:#{idx + 1}: #{line.strip}" if under_repl?(resolved)
          elsif (m = line.match(/^\s*require\s+["'](.+?)["']/))
            target = m[1]
            violations << "#{file}:#{idx + 1}: #{line.strip}" if target == "rubik/repl" || target.start_with?("rubik/repl/")
          end
        end
      end
    end

    assert_empty violations, "Core dirs must not require back into repl:\n#{violations.join("\n")}"
  end

  private

  def under_repl?(path)
    path == REPL_DIR || path.start_with?(REPL_DIR + File::SEPARATOR)
  end
end
```

**Key details (robustness to actual require patterns):**
- **`require_relative`** is resolved against the file's own directory (`File.expand_path(m[1], File.dirname(file))`) and checked for being under `lib/rubik/repl`. This catches `require_relative "../repl/..."`, `require_relative "../../repl/..."`, and any depth.
- **`require`** (non-relative) is checked against the `rubik/repl` namespace string. Stdlib/gem requires (e.g. `require "json"`, `require "monitor"`) never match, so no false positives.
- `Dir.glob` with `**/*.rb` recurses into subdirectories (e.g. `tools/builtins/`, `runtime/`), matching the review's scope of `orchestrator/**`, `runtime/**`, `tools/**`, `llm/**`.
- Uses `test_helper` + Minitest, matching every other unit test.
- Currently zero violations (verified: no `repl` reference exists in the four dirs), so the test is green today and only fails on a future regression.

**Verify:** `ruby -Itest test/unit/test_architectural_boundaries.rb` — green (0 violations).

---

## Verification (full)

Run each affected test file individually and confirm green:

```
ruby -Itest test/unit/test_self_evolving_tool_synthesis.rb
ruby -Itest test/unit/test_overlay_integrity.rb
ruby -Itest test/unit/test_architectural_boundaries.rb
```

Then run `git diff` and confirm only these files changed:
- `lib/rubik/runtime/overlay_storage.rb`
- `lib/rubik/tools/builtins/synthesis.rb`
- `lib/rubik/tools/registry.rb`
- `test/unit/test_self_evolving_tool_synthesis.rb`
- `test/unit/test_architectural_boundaries.rb`

---

## Architecture Decisions

- **Delete lives in `OverlayStorage` (A1):** The storage class already owns manifest + file persistence for save/list/load; delete is the symmetric operation and belongs there. Alternative (deleting files directly in the tool) was rejected because it would duplicate clean_name normalization and manifest handling and risk drift. Trade-off: `delete_command`/`delete_tool` are thin and mirror `save_*` exactly, keeping the SSOT in one class.
- **One `unsynthesize` tool, not two (A2):** The review explicitly asks for a single delete tool as the twin of both synthesize tools. A `kind` discriminator keeps the surface small. Alternative (separate `delete_command`/`delete_tool` tools) was rejected as redundant. Trade-off: callers must pass `kind`, but the aliases (`delete_tool`, `delete_command`) make the intent discoverable.
- **Revertible inverse restores the previous registration (A2):** Per AGENTS.md §1.A, the deletion effect is paired with its inverse. When a synthesized command/tool is deleted, the inverse restores whatever existed before (or nothing). This is the same pattern the synthesize twins already use, so it is consistent and testable. Trade-off: a deleted item is restored on context dispose rather than permanently gone — this is the intended protocol semantics (session unwind), not a bug.
- **Guard test resolves `require_relative` against the file dir (B1):** This is the only robust way to catch `require_relative "../repl/..."` at any depth without false positives. `require "rubik/repl/..."` is matched by namespace string. Alternative (regex on the literal token `repl`) was rejected because it would false-positive on stdlib/gem names containing "repl". Trade-off: the test is slightly more code, but it is precise and green today.

## Open Questions

- **`unsynthesize` on a built-in command/tool:** The tool does not currently guard against deleting a built-in (unlike `SynthesizeToolTool`, which refuses to shadow built-ins). Deleting a built-in command via `unsynthesize` would unregister it live and (for project/global scope) remove a file that may not exist. Should `unsynthesize` refuse when the target's origin is `:builtin` (tools) or when the command is non-custom (`@shell.commands[name][:custom] == false`)? Default: add the guard for symmetry with the synthesize twins, but confirm with the reviewer — it is a small, safe addition.
- **`!tools` REPL command:** The review notes `!commands` only lists and there is no `!tools`. This plan does not add a `!tools` bang command (out of scope for the two workstreams). Confirm whether a follow-up should add it.

---

## Implementation Log

> Status of the plan as implemented. Filled in after the Code stage was approved and committed.

### Result: ✅ Implemented & committed — `8d7542f` (`feat(tools): add unsynthesize tool to close synthesis CRUD gap`)

All steps (A1–A4, B1) implemented and approved by review. No new dependencies, no breaking changes, no unrelated refactors. AGENTS.md §6 checklist satisfied.

### Per-step status

| Step | Status | Notes |
|---|---|---|
| **A1** `OverlayStorage#delete_command`/`delete_tool` | ✅ Done | Mirrors `save_*` (clean_name normalization, scope→dir, `{ ok:, error: }`, `rescue StandardError`). **Plus** the reviewer's non-blocking note was folded in: a fail-closed guard raises on a corrupt manifest (`manifest_state(target_dir) == :corrupt`) instead of wiping it with `{}` — symmetric with the `record_hash` guard on the save path. |
| **A2** `UnsynthesizeTool` | ✅ Done | Twin of the two synthesize tools in `synthesis.rb`. Unregisters live (`@shell.unregister_command` / `@tool_registry.unregister`), deletes disk via `OverlayStorage#delete_*` for project/global scope, registers a revertible `on_dispose` inverse restoring the prior registration (AGENTS.md §1.A). **Plus** the reviewer's built-in guard was made mandatory: refuses to delete a built-in command (`previous_meta[:custom] == false`) or tool (`@tool_registry.origin(clean) == :builtin`), symmetric with the synthesize twins' refusal to shadow built-ins. |
| **A3** Wire into `Registry.build_default` | ✅ Done | `registry.register(UnsynthesizeTool.new(shell, registry, overlay_storage, runtime_manager: runtime_manager))` added after the two synthesize registrations. No new require needed (`builtins/synthesis` already loaded). |
| **A4** Critical regression tests | ✅ Done | `test_unsynthesize_tool_removes_live_and_disk` and `test_unsynthesize_command_removes_live_and_disk` added to `test_self_evolving_tool_synthesis.rb`. Both assert disk file removed + `registry.get(name).nil?` / `@shell.commands[name].nil?` + manifest entry removed. |
| **B1** Architectural guard test | ✅ Done | New `test/unit/test_architectural_boundaries.rb`. Resolves `require_relative` against each file's dir; matches `require "rubik/repl/..."` by namespace. **Plus** the reviewer's edge case was fixed during review iteration 1: `under_repl?` also matches the top-level `lib/rubik/repl.rb` module file (`path == File.join(LIB, "repl.rb")`), not just the `repl/` directory. |

### Deviations from plan

1. **A1 — corrupt-manifest guard added (reviewer note):** The plan's sketch deleted the manifest entry unconditionally. Implementation raises before touching the manifest when `manifest_state` is `:corrupt`, so a corrupt `.manifest.json` is never overwritten with `{}`. This mirrors the existing `record_hash` fail-closed behavior.
2. **A2 — built-in deletion guard made mandatory (reviewer note):** The plan listed this as an open question. Implementation refuses to `unsynthesize` a built-in command or tool, symmetric with the synthesize twins' refusal to shadow built-ins.
3. **B1 — top-level `repl.rb` matched (review iteration 1):** The first review pass REJECTED the guard test because `under_repl?` missed the top-level `lib/rubik/repl.rb` module file. Fixed by adding the `path == File.join(LIB, "repl.rb")` clause; test re-approved and green.

### Verification (as run)

```
ruby -Itest test/unit/test_self_evolving_tool_synthesis.rb   # 9 runs, 52 assertions, 0 failures
ruby -Itest test/unit/test_overlay_integrity.rb              # 18 runs, 97 assertions, 0 failures
ruby -Itest test/unit/test_architectural_boundaries.rb       # 1 run, 2 assertions, 0 failures
```

`git diff` confirmed only the 5 planned files changed:
- `lib/rubik/runtime/overlay_storage.rb`
- `lib/rubik/tools/builtins/synthesis.rb`
- `lib/rubik/tools/registry.rb`
- `test/unit/test_self_evolving_tool_synthesis.rb`
- `test/unit/test_architectural_boundaries.rb`

### Open items carried forward (not in this plan's scope)

- `!tools` REPL bang command (review notes `!commands` only lists; no `!tools` exists).
- The review's other findings (1, 3, 4, 6) remain open as separate follow-up workstreams.
