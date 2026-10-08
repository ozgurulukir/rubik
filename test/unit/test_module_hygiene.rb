# frozen_string_literal: true

require_relative "../test_helper"

class TestModuleHygiene < Minitest::Test
  BUILTIN_CLASSES = [
    "ReadFileTool", "WriteFileTool", "ListFilesTool", "ReplaceFileContentTool", "GrepSearchTool", "SearchSymbolsTool",
    "GetOutlineTool", "FindReferencesTool", "GetSymbolTool", "LSPDiagnosticsTool", "LSPHoverTool",
    "LSPDefinitionTool", "RunTestsTool", "RunCommandTool", "ManageTaskTool", "ExecReplCommandTool", "SynthesizeCommandTool",
    "SynthesizeToolTool", "UnsynthesizeTool", "InspectRuntimeTool", "ProvideServiceTool", "ApplyBufferTool",
    "RepairRuntimeTool", "AskQuestionTool", "InvokeSubagentTool", "ManageSubagentsTool", "SendMessageTool",
    "DefineSubagentTool", "DmesgTool", "StorageTool", "VakanuvisTool", "ShowFileTool", "FinishTool"
  ].freeze

  def test_builtins_loader_is_a_shim
    lines = line_count("tools/builtins.rb")
    assert lines < 60, "builtins.rb must stay a require-shim under 60 lines, got #{lines}"
  end

  def test_builtin_domain_files_stay_small
    files = Dir.glob(File.join(lib_root, "tools", "builtins", "*.rb"))
    expected = [
      "dmesg.rb", "exec.rb", "files.rb", "grep.rb", "interactive.rb", "lifecycle.rb", "lsp.rb",
      "runtime.rb", "send_message.rb", "show_file.rb", "skill.rb", "storage.rb", "subagent.rb",
      "subagent_lifecycle.rb", "symbols.rb", "synthesis.rb", "task.rb", "unsynthesize.rb", "vakanuvis.rb"
    ]
    assert_equal expected, files.map { |f| File.basename(f) }.sort,
                 "expected exactly the Plan 54 D-3 domain files + the later additions (vakanuvis included)"
    files.each do |f|
      lines = File.readlines(f).size
      assert lines < 400, "#{File.basename(f)} must stay under 400 lines, got #{lines}"
    end
  end

  def test_all_builtin_classes_loaded
    BUILTIN_CLASSES.each do |klass|
      assert Rubik::Tools.const_defined?(klass), "Rubik::Tools::#{klass} missing after the split"
    end
  end

  def test_build_default_registers_all_builtin_tools
    dir = Dir.mktmpdir("rubik_hygiene")
    begin
      buffer_manager = Rubik::Buffer::Manager.new(root_dir: dir)
      registry = Rubik::Tools::Registry.build_default(buffer_manager: buffer_manager, root_dir: dir)
      assert_equal 33, registry.list.size, "build_default must register exactly the 33 builtin tools"
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_loop_stays_a_coordinator
    lines = line_count("orchestrator/loop.rb")
    assert lines < 500, "orchestrator/loop.rb must stay a coordinator under 500 lines, got #{lines}"
  end

  def test_orchestrator_collaborators_stay_small
    Dir.glob(File.join(lib_root, "orchestrator", "*.rb")).each do |f|
      next if File.basename(f) == "loop.rb"

      lines = File.readlines(f).size
      assert lines < 400, "#{File.basename(f)} must stay under 400 lines, got #{lines}"
    end
  end

  def test_config_module_hygiene
    assert line_count("config.rb") < 300, "config.rb must stay under 300 lines"
    assert line_count("config/defaults.rb") < 220, "config/defaults.rb must stay under 220 lines"
    assert line_count("config/deep_ops.rb") < 180, "config/deep_ops.rb must stay under 180 lines"
    assert line_count("config/store.rb") < 200, "config/store.rb must stay under 200 lines"
    assert line_count("config/model_catalog.rb") < 200, "config/model_catalog.rb must stay under 200 lines"
  end

  def test_plugin_module_hygiene
    assert line_count("plugin/storage.rb") < 300, "plugin/storage.rb must stay under 300 lines"
    assert line_count("plugin/manager.rb") < 350, "plugin/manager.rb must stay under 350 lines"
  end

  def test_runtime_manager_module_hygiene
    assert line_count("runtime/manager.rb") < 260, "runtime/manager.rb must stay a coordinator under 260 lines (G4)"
    assert line_count("runtime/fiber_ordering.rb") < 120, "runtime/fiber_ordering.rb must stay a pure sort under 120 lines"
    assert line_count("runtime/fiber_retry_gate.rb") < 120, "runtime/fiber_retry_gate.rb must stay the retry gate under 120 lines"
  end

  def test_task_manager_module_hygiene
    assert line_count("runtime/task_manager.rb") < 350, "runtime/task_manager.rb must stay under 350 lines"
    assert line_count("tools/builtins/task.rb") < 250, "tools/builtins/task.rb must stay under 250 lines"
    assert line_count("repl/commands/tasks.rb") < 200, "repl/commands/tasks.rb must stay under 200 lines"
  end

  def test_tool_declaration_module_hygiene
    assert line_count("tools/declaration.rb") < 100, "declaration.rb must stay a frozen VO under 100 lines"
    assert line_count("tools/catalog.rb") < 140, "catalog.rb must stay a projection under 140 lines"
    assert line_count("prompt/tool_teachings.rb") < 90, "tool_teachings.rb must stay a keyed prose table under 90 lines"
  end

  def test_service_catalog_module_hygiene
    assert line_count("repl/service_catalog.rb") < 380,
           "service_catalog.rb must stay the single ordered declaration table under 380 lines"
    assert line_count("runtime/service_definition.rb") < 60, "service_definition.rb must stay a pure data VO under 60 lines"
    assert line_count("runtime/service_registration.rb") < 50, "service_registration.rb must stay a thin spine under 50 lines"
    assert line_count("tools/services.rb") < 100, "tools/services.rb must stay a tier table under 100 lines"
    # composition.rb's < 120 cap lives once, in test_repl_composition.rb
    # ("the escape valve that keeps shell.rb under its decoupling cap").
  end

  def test_runtime_core_module_hygiene
    assert line_count("runtime/manager.rb") < 350, "runtime/manager.rb must stay under 350 lines"
    # 340 (was 320): arch-strong 2026-10-08 (candidate 5) — the coeffect
    # alias bridge got one home in Context: the three-spelling contract doc
    # + the protected resolve_coeffect walker absorbing resolve_with_alias,
    # with LEGACY_ALIASES aliased beside CANONICAL_OF as the SSOT pointer.
    assert line_count("runtime/context.rb") < 340, "runtime/context.rb must stay under 340 lines"
  end

  def test_subagent_module_hygiene
    assert line_count("orchestrator/subagent/budget.rb") < 150, "budget.rb must stay under 150 lines"
    assert line_count("orchestrator/subagent/supervisor.rb") < 350, "supervisor.rb must stay under 350 lines"
    # 365 (was 350): the guarded-transition discipline (fail_run failure
    # drain, per-wake terminal guards) costs real lines after the state
    # vocabulary itself already moved to lifecycle.rb.
    # 385 (was 365): session-review 2026-10-07 (fffcr B3/B4/B11) — grant
    # telemetry + live-result clearing + grant-aware halt wording.
    assert line_count("orchestrator/subagent/instance.rb") < 385, "instance.rb must stay under 385 lines"
    # 130: the lifecycle vocabulary (TRANSITIONS table + predicates + the
    # guarded transition! seam) extracted from instance.rb — a pure state
    # machine deserves its own page, not headroom to grow back.
    assert line_count("orchestrator/subagent/lifecycle.rb") < 130, "lifecycle.rb must stay the vocabulary table under 130 lines"
    assert line_count("orchestrator/subagent/step_runner.rb") < 250, "step_runner.rb must stay under 250 lines"
    # 200 (was 150): the dmesg emission door (SUBSYSTEM / SEVERITIES / emit)
    # — bug-llm-timeout-observability — routes every subagent-plane event to
    # subsystem :subagent with an operationally-matched severity in the one
    # vocabulary home (user-approved stretch, 2026-10-03).
    # 210 (was 200): session-review 2026-10-07 (fffcr B11) — grant/step cycle
    # markers on repeated budget pauses.
    assert line_count("orchestrator/subagent/notices.rb") < 210, "notices.rb must stay under 210 lines"
    assert line_count("orchestrator/subagent/resilience.rb") < 150, "resilience.rb must stay under 150 lines"
    assert line_count("orchestrator/subagent/concurrency_gate.rb") < 100, "concurrency_gate.rb must stay under 100 lines"
    assert line_count("orchestrator/subagent/type_registry.rb") < 200, "type_registry.rb must stay under 200 lines"
    assert line_count("orchestrator/subagent/storage_id.rb") < 60, "storage_id.rb must stay under 60 lines"
    assert line_count("orchestrator/subagent/reuse.rb") < 150, "reuse.rb must stay under 150 lines"
    assert line_count("orchestrator/subagent/reaper.rb") < 150, "reaper.rb must stay under 150 lines"
    assert line_count("orchestrator/subagent/completion.rb") < 100, "completion.rb must stay under 100 lines"
    assert line_count("orchestrator/subagent/dependency.rb") < 400, "dependency.rb must stay under 400 lines"
    # 365 (was 350): the DECLARATION hoist carries archetype/spawn/write-grant/
    # maestro policy per tool, and invoke_subagent holds its dynamic
    # max_steps schema in one params_schema_for method (single-source).
    # 375 (was 365): session-review 2026-10-07 (fffcr B5/B10) — three-dialect
    # conversation_ids normalization, roster hint, truncation URI in wait.
    assert line_count("tools/builtins/subagent.rb") < 375, "subagent.rb must stay under 375 lines"
    assert line_count("tools/builtins/subagent_lifecycle.rb") < 150, "subagent_lifecycle.rb must stay under 150 lines"
    assert line_count("repl/commands/subagents.rb") < 200, "subagents.rb must stay under 200 lines"
  end

  def test_kernel_module_hygiene
    assert line_count("kernel/dmesg.rb") < 180, "kernel/dmesg.rb must stay under 180 lines"
    # 90 (was 80): session-review 2026-10-07 (fffcr B1) — bounded payload
    # rendering (safe_utf8-guarded key=value) joined format_line here.
    assert line_count("kernel/record.rb") < 90, "kernel/record.rb must stay under 90 lines"
    assert line_count("kernel/dispatcher.rb") < 180, "kernel/dispatcher.rb must stay under 180 lines"
    # 165 (was 150): notify_transition escalates severity/subsystem by target
    # state (paused_error/failed -> err, budget parks -> warn; subagent units
    # under subsystem :subagent) so a stalled unit surfaces in
    # dmesg(level: "err") — bug-llm-timeout-observability (user-approved
    # stretch, 2026-10-03).
    assert line_count("kernel/unit.rb") < 165, "kernel/unit.rb must stay under 165 lines"
    assert line_count("kernel/init.rb") < 200, "kernel/init.rb must stay under 200 lines"
    assert line_count("event_bus.rb") < 80, "event_bus.rb must stay under 80 lines"
  end

  def test_repl_terminal_guard_hygiene
    # 170 (was 120, Plan 109): the wake primitives (idle_and_empty? /
    # safe_wakeup! / with_collecting) joined the guard — still
    # single-purpose terminal safety.
    assert line_count("repl/terminal_guard.rb") < 170, "terminal_guard.rb must stay under 170 lines"
  end

  def test_ast_module_hygiene
    assert line_count("ast/treesitter_extractor.rb") < 100, "treesitter_extractor.rb must stay under 100 lines"
    assert line_count("ast/graph.rb") < 280, "graph.rb must stay under 280 lines"
  end

  def test_sandbox_driver_hygiene
    assert line_count("sandbox/driver/docker.rb") < 140, "docker.rb must stay under 140 lines"
  end

  private

  def lib_root
    File.expand_path("../../lib/rubik", __dir__)
  end

  def line_count(rel_path)
    File.readlines(File.join(lib_root, rel_path)).size
  end
end
