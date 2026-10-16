# frozen_string_literal: true

module Rubik
  module Prompt
    # Tool teachings keyed by canonical tool name (architecture review
    # 2026-10-01, candidate 1): the sentences that teach HOW a specific tool
    # is used live here, one key per tool, instead of being embedded unnamed
    # in Doctrine.operational_rules_xml's heredoc. Identity (the tool) lives in
    # its Tools::Declaration; prose (the presentation) lives here — a prompt
    # layer concern. test_tool_teachings welds the two: every key must
    # resolve to a declared (Catalog) tool, so a rename that forgets the
    # prompt fails the suite.
    #
    # The strings are interpolated into the operational rules HEREDOC at the
    # same positions they originally occupied — the rendered rules are
    # byte-identical (pinned by the substring tests in
    # test_structured_context_builder, test_agent_command_contract,
    # test_buffer_apply_conflict, test_repl_tool_separation_and_guardrails).
    module ToolTeachings
      TEACHINGS = {
        "replace_file_content" =>
          "For modifying existing files, prefer `replace_file_content` with exact verbatim `target_content` " \
          "(or `old_content`) and `replacement_content` (or `new_content`).",
        "write_file" =>
          "For creating new files or completely rewriting files, use `write_file`.",
        "apply_buffer" =>
          "All edits stage safely into the in-memory buffer. Call `apply_buffer` to persist buffer edits to disk. " \
          "If `apply_buffer` reports `[CONFLICT]` due to external modifications (e.g. from code formatters or " \
          "external processes), inspect latest disk changes with `read_file(path: \"...\", reload: true)` or " \
          "overwrite deliberately with `apply_buffer(force: true)`.",
        "synthesize_tool" =>
          "When you need a specialized capability not available in the built-in toolbelt (such as custom AST " \
          "transformers, data converters, or domain-specific benchmarkers), dynamically create and register your " \
          "own tool at runtime using `synthesize_tool(name: '...', description: '...', code: '->(args) { ... }')`.",
        "storage" =>
          "Persist agent workfiles — goals, plans, reviews, and work notes — in the central " \
          "`storage` database (`storage` tool: put/get/list/search/set_ref/delete), NOT as scattered files in " \
          "the repository worktree. Read, list, and search all entity types (`goal`, `plan`, `memory`, `wiki`, " \
          "`transcript`, `review`, `note`) via `storage` or `read_file(path: 'rubik://storage/<type>/<id>')` " \
          "(browse with `rubik://storage/index` and `rubik://storage/<type>` listings); write durable `memory` " \
          "cards and compiled `wiki` pages through `vakanuvis` (`record` / `digest`) whenever `vakanuvis` is in " \
          "your toolbelt, reserving direct `storage` `put` on `memory`/`wiki` for sessions where `vakanuvis` is " \
          "unavailable.",
        "run_command" =>
          "GitHub facts must be verified, not assumed: after `gh pr merge` (which can succeed with EMPTY output) " \
          "confirm the merge with `gh pr view <number> --json state`; `mergeable: UNKNOWN` right after a push means " \
          "GitHub is still recomputing — wait briefly and re-check instead of rebasing; `gh pr checks` exits 1 both " \
          "for failing checks and for repos with no CI — disambiguate with `gh pr view --json statusCheckRollup`. " \
          "In repos that intentionally commit no lockfile, install dependencies with `npm install --no-package-lock` " \
          "(or the package manager's equivalent) so setup does not dirty the worktree with a new lockfile.",
        "show_file" =>
          "When the user asks to SEE a stored entity (review report, plan, ...), use " \
          "`show_file(path: 'rubik://storage/...')` — it renders the full content directly to their terminal " \
          "while your context stays lean; only fall back to read_file when YOU must reason about the content.",
        "vakanuvis" =>
          "The background chronicler keeps compiled knowledge (memory cards, wiki pages) in rubik://storage. " \
          "At task start — and again after any compaction — ask it with `vakanuvis(action: 'recall', query: '...')` " \
          "instead of pre-loading pages: it returns a deterministic digest plus rubik:// source links. When " \
          "dispatching a subagent, paste the relevant recall digest (or its rubik:// link) into the task brief. " \
          "At the end of a task, persist only the durable knowledge with `vakanuvis(action: 'record', topic: '...', " \
          "body: '...')` — memory writes go through record (ref minting, upsert, supersede come free), never " \
          "through raw storage puts when `vakanuvis` is available. Recall is keyword-AND over card/page text, so END " \
          "every recorded body and digest query with its own vocabulary: include a `Keywords:` line listing 5-10 " \
          "synonyms in BOTH working languages (e.g. TR + EN) — a Turkish query cannot otherwise find an English page. " \
          "If recall is too shallow, queue `vakanuvis(action: 'digest', query: '...')`: it returns a deterministic " \
          "receipt and compiles the wiki page asynchronously. Make the session close a standard digest point: review " \
          "the session's new cards, queue one digest per open topic, and let the home index refresh.",
        "prune_context" =>
          "When long sessions leave stale exploration and superseded tool output weighing on the ROOT window, " \
          "check `prune_context(action: 'status')` (window estimate vs ceiling, staged plan state) and force a " \
          "cleanup with `prune_context(action: 'prune', reason: '...')`: it queues an LLM-proposed, " \
          "harness-validated keep/drop/summarize plan that applies at the NEXT turn boundary — the call returns " \
          "a deterministic receipt and never blocks. Goal/task statements, decisions and recent context are " \
          "always preserved; deterministic compaction remains the emergency safety net."
      }.freeze

      module_function

      def teaching_for(tool_name) = TEACHINGS[tool_name.to_s]
    end
  end
end
