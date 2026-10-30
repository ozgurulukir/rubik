# frozen_string_literal: true

require_relative "../test_helper"

# Doctrine invariants (architecture review 2026-10-01, candidate 2,
# Phase 4): tests assert PROPERTIES of the policy prose against the
# Prompt::Doctrine SSOT — "rule 2 delegates all edits to coder
# subagents", "every execution-mode header pins the coder archetype" —
# instead of pinning prose substrings through the assembler. Absolute
# wording is pinned byte-for-byte by test_prompt_golden_output; the
# assembler's structure by test_structured_context_builder.
class TestPromptDoctrine < Minitest::Test
  def rules = Rubik::Prompt::Doctrine.operational_rules_xml

  def header(mode) = Rubik::Prompt::Doctrine.role_header(mode)

  def guidance = Rubik::Prompt::Doctrine.orchestration_guidance_bullets.join("\n")

  # ---------- the nine numbered rules exist ----------

  def test_all_nine_numbered_rules_are_present
    [
      "1. Code Exploration & Review", "2. Code Editing & Targeted Changes",
      "3. Testing & Execution", "4. REPL Bang Commands",
      "5. Autonomous Tool Synthesis", "6. Output Budget & Conciseness",
      "7. Subagent Delegation & Parallelism (Maestro)",
      "8. Runtime Introspection, Self-Healing & Human Feedback",
      "9. Central Storage & Clean Worktree"
    ].each { |title| assert_includes rules, title, "rule #{title} must exist" }
  end

  # ---------- rules 2/3: the maestro override ----------

  def test_rule_two_delegates_all_edits_to_coder_subagents
    assert_includes rules, "2. Code Editing & Targeted Changes: MAESTRO OVERRIDE"
    assert_includes rules, "route ALL edits through 'coder' subagents"
    assert_includes rules, "never stage edits in your own context"
  end

  def test_rule_three_delegates_execution_wholesale_to_subagents
    assert_includes rules, "3. Testing & Execution: MAESTRO OVERRIDE"
    assert_includes rules, "subagents run tests and commands"
    assert_includes rules, "never execute them yourself"
  end

  # ---------- rule 4: the 2026-09-30 consistency audit, executable ----------

  def test_rule_four_keeps_repl_commands_session_safe_under_maestro_doctrine
    assert_includes rules, "4. REPL Bang Commands"
    assert_includes rules, "session-safe commands"
    assert_includes rules, "never travel through REPL commands"
    assert_includes rules, "they are delegated to subagents"

    # The audit's core refutation, executed across EVERY prose surface:
    # no doctrine text may tell the maestro to use direct tools hands-on.
    [rules, header(:plan), header(:goal), header(:default)].each do |surface|
      refute_includes surface, "always use direct tools",
                      "doctrine must not contradict the maestro override"
    end
  end

  # ---------- rule 7: delegation is the default operating mode ----------

  def test_rule_seven_frames_delegation_as_the_default_operating_mode
    assert_includes rules, "7. Subagent Delegation & Parallelism (Maestro): As the maestro you orchestrate"
    assert_includes rules, "is delegated via `invoke_subagent`, in every mode"
    assert_includes rules, "MUST use 'coder' for code modifications"
  end

  def test_rule_seven_states_the_auto_wake_contract
    assert_includes rules, "the runtime automatically wakes you with a dedicated notification-evaluation turn"
    assert_includes rules, "conclude your turn and liberate the prompt so the user can interact concurrently"
    assert_includes rules,
                    "Call `#{Rubik::Orchestrator::Subagent::Notices.wait_hint_template}` only when synchronous waiting is strictly required"
  end

  def test_rule_seven_teaches_proactive_budget_and_transcript_chaining
    assert_includes rules, "allocate sufficient step budget (e.g. `max_steps: 100-140`)"
    assert_includes rules, "hand the successor the predecessor's canonical transcript reference"
    assert_includes rules, "`read_file('rubik://subagent/<storage-id>/transcript')`"
    refute_includes rules, "rubik://storage/<predecessor-id>/transcript",
                    "the invalid storage-path teaching must be gone (issue #129)"
    assert_includes rules, "Consume subagents' structured reports (Outcome, Changes/Locations, Verification/Findings, Assumptions)"
  end

  def test_rule_eight_teaches_introspection_and_structured_questions
    assert_includes rules, "repair failed services via `repair_runtime_service`"
    assert_includes rules, "use `ask_question` with structured multiple-choice options"
  end

  # ---------- role headers ----------

  def test_goal_header_mandates_staged_subagent_pipeline
    goal = header(:goal)
    assert_includes goal, "SUPERVISOR", "the maestro must be framed as the pipeline supervisor"
    assert_includes goal, "(maestro)", "header must pin the pure-orchestrator doctrine"
    assert_includes goal, "never in yours", "all research/code/verification belongs to subagent contexts"
    assert_includes goal, "Keep YOUR context lean", "header must forbid code/test dumps in the maestro's context"
    assert_includes goal, "invoke_subagent", "header must mandate subagent dispatch"
    assert_includes goal, "'coder'", "header must pin the coder archetype for file changes"
    assert_includes goal, "extend_budget", "header must teach budget escalation over task absorption"
    assert_includes goal, "rubik://goal/state", "header must publish the live goal snapshot URL"
    assert_includes goal, "run_tests", "verification duty stays explicit (delegated verifier stage)"
    assert_includes goal, "ask_question", "header must keep the maestro answering duty"
    refute_includes goal, "run final `run_tests` yourself",
                    "the self-verification clause must be gone — verification is delegated"
    refute_includes goal, "Use `write_file` to prepare changes",
                    "old inline-implementer language must be gone"
  end

  def test_default_header_frames_init_zero_as_maestro
    default = header(:default)
    assert_includes default, "maestro coding orchestrator", "default mode is maestro too (user ruling: ALWAYS)"
    assert_includes default, "ALWAYS work through subagents", "delegation is the default operating mode"
    assert_includes default, "never in your own context", "execution never runs in the maestro's context"
    assert_includes default, "redeploy", "reuse guidance is part of the default persona"
    refute_includes default, "pair programming assistant", "old hands-on persona must be gone"
    # The override itself is the rules' job (rules 2-3 tests pin it); the
    # header only must not contradict it.
    refute_includes default, "always use direct tools"
  end

  def test_plan_header_forbids_mutating_tools
    plan = header(:plan)
    assert_includes plan, "PLAN-ONLY mode"
    assert_includes plan, "Do NOT call apply_buffer, write_file, replace_file_content, run_tests, or run_command"
  end

  def test_every_execution_mode_header_pins_the_coder_archetype_for_edits
    # :plan is text-only (no execution, no archetypes) — the invariant
    # covers the two execution modes.
    [:goal, :default].each do |mode|
      assert_includes header(mode), "'coder'",
                      "#{mode} header must pin the coder archetype for file modifications"
    end
  end

  def test_operational_rules_and_headers_agree_on_delegation
    surfaces = { "rules" => rules, "goal header" => header(:goal), "default header" => header(:default) }
    surfaces.each do |label, surface|
      assert_includes surface, "subagent", "#{label} must teach subagent delegation"
      refute_includes surface, "always use direct tools", "#{label} must not contradict the override"
    end
  end

  # ---------- guidance + notice dialect ----------

  def test_orchestration_guidance_reuses_notice_hint_dialect
    notices = Rubik::Orchestrator::Subagent::Notices
    assert_includes guidance, notices.wait_hint_template
    assert_includes guidance, notices.extend_budget_hint("[...]")
    assert_includes guidance, "MUST use 'coder' for code changes/bug fixes"
    assert_includes guidance, "automatically wake you with a notification-evaluation turn while you are idle"

    [notices.wait_hint_template, notices.extend_budget_hint("[...]")].each do |hint|
      assert_includes guidance, hint
      refute_includes hint, '"', "hint dialect is single-quoted; Array#inspect is banned"
    end
  end

  # bug-llm-timeout-observability follow-up: the guidance must teach the
  # error-pause recovery path symmetric with budget escalation, and the
  # staged-dispatch rule must not imply an error-paused predecessor
  # cancels its dependents (dependency.rb: :dead only on failed?).
  def test_orchestration_guidance_teaches_error_pause_recovery_and_dependency_symmetry
    notices = Rubik::Orchestrator::Subagent::Notices
    assert_includes guidance, "(PAUSED_ERROR) is also NOT terminal"
    assert_includes guidance, notices.resume_hint("[...]")
    assert_includes guidance, "budget- or error-paused predecessor keeps them queued"
  end

  # ---------- format_user_task (the compactor byte contract) ----------

  def test_user_task_wrapper_is_emitted_exactly_once_per_format_call
    out = Rubik::Prompt::ContextBuilder.format_user_task("Ship it")
    assert_equal 1, out.scan("<user_task>").size
    assert_equal 1, out.scan("</user_task>").size
    assert out.start_with?("<user_task>\n"), "compactor pins the exact opening bytes"
    assert out.end_with?("\n</user_task>"), "compactor pins the exact closing bytes"
  end

  # ---------- issue #166: active tools, plan mode, exploration vs delegation ----------

  def test_operational_rules_omit_gated_tool_teachings_when_coeffects_unsatisfied
    minimal_tools = ["read_file", "list_files", "grep_search", "invoke_subagent", "manage_subagents", "finish"]
    filtered_rules = Rubik::Prompt::Doctrine.operational_rules_xml(active_tools: minimal_tools, mode: :default)

    ["storage", "vakanuvis", "show_file", "prune_context"].each do |gated_tool|
      teaching = Rubik::Prompt::ToolTeachings.teaching_for(gated_tool)
      refute_includes filtered_rules, teaching,
                      "#{gated_tool} teaching must not render when #{gated_tool} is absent from active_tools"
    end
    assert_includes filtered_rules, "Keep the repository worktree free of scattered agent workfiles"

    full_tools = minimal_tools + ["storage", "vakanuvis", "show_file", "prune_context"]
    full_rules = Rubik::Prompt::Doctrine.operational_rules_xml(active_tools: full_tools, mode: :default)
    ["storage", "vakanuvis", "show_file", "prune_context"].each do |gated_tool|
      teaching = Rubik::Prompt::ToolTeachings.teaching_for(gated_tool)
      assert_includes full_rules, teaching,
                      "#{gated_tool} teaching must render when #{gated_tool} is present in active_tools"
    end
  end

  def test_goal_header_and_orchestration_guidance_respect_active_tools
    without_gated = ["read_file", "invoke_subagent", "manage_subagents", "finish"]
    goal_without = Rubik::Prompt::Doctrine.role_header(:goal, goal_ledger: true, active_tools: without_gated)
    refute_includes goal_without, "vakanuvis",
                    "goal header must not instruct calling vakanuvis when vakanuvis is absent"
    refute_includes goal_without, "(`storage` tool)",
                    "goal header must not instruct calling storage tool when storage is absent"
    refute_includes goal_without, "update_goal_ledger(patch:",
                    "goal header must not instruct calling update_goal_ledger when update_goal_ledger is absent"

    guidance_without = Rubik::Prompt::Doctrine.orchestration_guidance_bullets(active_tools: without_gated).join("\n")
    refute_includes guidance_without, "Chronicler briefs",
                    "orchestration guidance must omit vakanuvis brief instructions when vakanuvis is absent"

    with_gated = without_gated + ["storage", "vakanuvis", "update_goal_ledger"]
    goal_with = Rubik::Prompt::Doctrine.role_header(:goal, goal_ledger: true, active_tools: with_gated)
    assert_includes goal_with, "(`vakanuvis` record/recall; see rule 9)"
    assert_includes goal_with, "(`storage` tool)"
    assert_includes goal_with, "update_goal_ledger(patch:"

    guidance_with = Rubik::Prompt::Doctrine.orchestration_guidance_bullets(active_tools: with_gated).join("\n")
    assert_includes guidance_with, "Chronicler briefs"
  end

  def test_plan_mode_rules_and_header_do_not_direct_tool_calls
    plan_header = Rubik::Prompt::Doctrine.role_header(:plan)
    plan_rules = Rubik::Prompt::Doctrine.operational_rules_xml(active_tools: [], mode: :plan)

    assert_includes plan_header, "No tools are exposed in PLAN-ONLY mode — do NOT emit tool calls or JSON tool blocks"
    assert_includes plan_rules, "1. Code Exploration & Review (PLAN-ONLY — no tool calls):"
    assert_includes plan_rules, "without invoking tools"
    assert_includes plan_rules, "In PLAN-ONLY mode, do not synthesize tools"
    assert_includes plan_rules, "In PLAN-ONLY mode no tools are exposed, so you do NOT invoke `invoke_subagent` or any other tools"
    assert_includes plan_rules, "instead of invoking runtime or question tools"

    ["storage", "vakanuvis", "show_file", "prune_context", "synthesize_tool"].each do |tool_name|
      refute_includes plan_rules, Rubik::Prompt::ToolTeachings.teaching_for(tool_name),
                      "plan mode rules must not embed #{tool_name} invocation teaching"
    end
  end

  def test_exploration_and_delegation_rules_are_consistent_across_modes
    default_hdr = header(:default)
    goal_hdr = header(:goal)
    exec_rules = rules

    assert_includes exec_rules,
                    "while you may use read-only tools directly for quick orientation (rule 1), " \
                    "broader codebase exploration, code changes, and verification — all execution work — is delegated via `invoke_subagent`"
    refute_includes exec_rules, "ALL execution work (exploration, code changes, verification) is delegated",
                    "rule 7 must not contradict rule 1's direct read-only orientation permission"
    assert_includes default_hdr,
                    "while you MAY explore read-only (`list_files`, `grep_search`, `read_file`) for quick orientation, " \
                    "broader codebase research, all code changes, and all verification run in subagent contexts"
    assert_includes goal_hdr,
                    "You may perform lightweight read-only inspection (`list_files`, `grep_search`, `read_file`) to orient " \
                    "and shape assignments, while all broader research, code changes, and verification run in subagent contexts, never in yours"
  end
end
