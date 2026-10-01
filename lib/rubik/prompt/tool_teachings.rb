# frozen_string_literal: true

module Rubik
  module Prompt
    # Tool teachings keyed by canonical tool name (architecture review
    # 2026-10-01, candidate 1): the sentences that teach HOW a specific tool
    # is used live here, one key per tool, instead of being embedded unnamed
    # in build_operational_rules_xml's heredoc. Identity (the tool) lives in
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
          "Persist agent workfiles — goals, plans, memory notes, wiki knowledge, reviews — in the central " \
          "`storage` database (`storage` tool: put/get/list/search/set_ref/delete), NOT as scattered files in " \
          "the repository worktree. Read entities back with `read_file(path: 'rubik://storage/<type>/<id>')`; " \
          "browse with `rubik://storage/index` and `rubik://storage/<type>` listings.",
        "show_file" =>
          "When the user asks to SEE a stored entity (review report, plan, ...), use " \
          "`show_file(path: 'rubik://storage/...')` — it renders the full content directly to their terminal " \
          "while your context stays lean; only fall back to read_file when YOU must reason about the content."
      }.freeze

      module_function

      def teaching_for(tool_name) = TEACHINGS[tool_name.to_s]
    end
  end
end
