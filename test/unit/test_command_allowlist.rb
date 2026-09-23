# frozen_string_literal: true

require_relative "../test_helper"

# Plan: komut-allowlist-güvenlik-kapısı (2026-09-14) — Paket A/C/F kilidi.
# Operator-controlled command allowlist gate in Guard#verify_command_safety!.
class TestCommandAllowlist < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_allowlist_test")
    @audit = File.join(@tmp, "audit.log")
    @guard = Rubik::Security::Guard.new(
      command_allowlist: ["node .gitnexus/run.cjs"],
      audit_log_path: @audit
    )
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  rescue StandardError
    nil
  end

  def test_allowlisted_prefix_passes
    assert @guard.verify_command_safety!('node .gitnexus/run.cjs impact "x" --repo .')
  end

  def test_non_allowlisted_binary_still_blocked
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("node evil.js")
    end
  end

  def test_narrow_prefix_does_not_cover_other_subcommands
    # "node .gitnexus/run.cjs" must not rescue "node" alone
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("node .gitnexus/other.js")
    end
  end

  def test_catastrophic_fallback_regex_not_bypassed_by_allowlist
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("node .gitnexus/run.cjs impact x ; rm -rf /")
    end
  end

  def test_partial_allowlist_cannot_rescue_dangerous_chain_sibling
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("node .gitnexus/run.cjs impact x && node evil.js")
    end
  end

  def test_dangerous_builtin_source_never_rescuable
    @guard.set_allowed_commands(["source"])
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("source ~/.bashrc")
    end
  end

  def test_set_allowed_commands_reconfigures_live
    @guard.set_allowed_commands(["git push"])
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_command_safety!("node .gitnexus/run.cjs status")
    end
    @guard.set_allowed_commands(["node .gitnexus/run.cjs"])
    assert @guard.verify_command_safety!("node .gitnexus/run.cjs status")
  end

  def test_empty_allowlist_keeps_fail_closed_default
    guard = Rubik::Security::Guard.new(audit_log_path: @audit)
    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_command_safety!("node .gitnexus/run.cjs status")
    end
    assert_equal [], guard.command_allowlist
  end

  def test_audit_log_records_allowed_and_blocked_actions
    @guard.verify_command_safety!("node .gitnexus/run.cjs status")
    begin
      @guard.verify_command_safety!("node evil.js")
    rescue Rubik::Security::BlockedWriteError
      nil
    end
    actions = File.readlines(@audit).filter_map do |l|
      JSON.parse(l)["action"]
    rescue StandardError
      nil
    end
    assert_includes actions, "allowed_command"
    assert_includes actions, "blocked_command"
  end

  # Paket C: the blocked-command guidance must point at the correct,
  # operator-only command gate — not the directory fence. (The per-situation
  # variants only mention !allow-cmd; !allow-dir belongs to the sandbox-gate
  # message, not command blocks.)
  def test_run_command_tool_blocked_message_points_to_allow_cmd
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)

    tool = Rubik::Tools::RunCommandTool.new(guard: shell.guard, runner: shell.sandbox_runner, root_dir: @tmp)
    result = tool.execute("command" => "node definitely-not-allowlisted.js")

    assert_includes result, "Security blocked"
    assert_includes result, '!allow-cmd add "node definitely-not-allowlisted.js"'
    refute_includes result, "!allow-dir"
  end

  # Paket F: tool contract advertises the operator gate (not the agent gate).
  def test_run_command_tool_description_documents_operator_allowlist
    registry = Rubik::Tools::Registry.new
    registry.register(Rubik::Tools::RunCommandTool.new(guard: @guard, runner: Rubik::Sandbox::Runner.new(root_dir: @tmp), root_dir: @tmp))
    desc = registry.get("run_command").description

    assert_includes desc, "!allow-cmd"
    assert_includes desc, "human operator"
  end

  def test_repl_allow_cmd_add_and_audit_logging
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    guard = Rubik::Security::Guard.new(audit_log_path: @audit)
    parts = Rubik::REPL::Composition.build(config: cfg)
    parts.guard = guard
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp, parts: parts)

    shell.execute_input('!allow-cmd add "bash --version"')
    entries = shell.config.fetch("security.command_allowlist", [])
    assert_includes entries, "bash --version"

    actions = File.readlines(@audit).filter_map do |l|
      JSON.parse(l)["action"]
    rescue StandardError
      nil
    end
    assert_includes actions, "allowlist_add"
  end

  def test_repl_allow_cmd_help_does_not_add_help_command
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)

    shell.execute_input("!allow-cmd help")
    entries = shell.config.fetch("security.command_allowlist", [])
    refute_includes entries, "help"
    assert_includes out.string, "Usage: !allow-cmd"
  end

  def test_allowlist_matches_windows_exe_extension
    mock_ast = Struct.new(:commands).new([Struct.new(:argv).new(["node.exe", ".gitnexus/run.cjs"])])
    Rubik::Platform.stub :windows?, true do
      assert @guard.command_allowlisted?(mock_ast)
    end
  end

  def test_repl_allow_cmd_shorthand_broad_without_force_is_blocked
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)

    shell.execute_input('!allow-cmd "node"')
    entries = shell.config.fetch("security.command_allowlist", [])
    refute_includes entries, "node"
    # A broad single-token dangerous entry (e.g. "node") is blocked
    # fail-closed regardless of --force — see test_repl_allow_cmd_shorthand_broad_single_token_blocked_even_with_force.
    assert_includes out.string, "broad, single-token dangerous command"
  end

  # Fix (Cluster A): even --force cannot allowlist a broad, single-token
  # dangerous entry — it grants unbounded command execution (e.g. `node -e
  # 'malicious()'` RCE). Forced broad single-token entries are now blocked
  # fail-closed. Use a narrow prefix (e.g. "node .gitnexus/run.cjs").
  def test_repl_allow_cmd_shorthand_broad_single_token_blocked_even_with_force
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)

    shell.execute_input('!allow-cmd "node" --force')
    entries = shell.config.fetch("security.command_allowlist", [])
    refute_includes entries, "node"
    assert_includes out.string, "broad, single-token dangerous command"
  end

  def test_guard_safe_probe_requires_clean_ast_without_parse_warnings
    # When Classifier returns dangerous with parse_warnings, safe-probe exemption must not apply
    mock_cmd = Struct.new(:classification, :argv, :inner_commands, :matched_rule, :classification_reason, :overriding_option, :command).new(:dangerous, ["bash", "--version"], [], "bash", "blocked by default rule: bash", nil, ["bash"])
    mock_ast = Struct.new(:classification, :commands, :parse_warnings).new(
      :dangerous,
      [mock_cmd],
      ["syntax error in probe expression"]
    )

    Rubik::Security::Classifier.stub :classify, mock_ast do
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!("bash --version")
      end
    end
  end

  def test_process_driver_cmd_constructs_allows_npm_start_and_blocks_start
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    Rubik::Platform.stub :windows?, true do
      # Harmless commands with "start" as an argument must NOT be blocked
      assert_nil driver.send(:verify_cmd_specific_safe!, "npm start")
      assert_nil driver.send(:verify_cmd_specific_safe!, "yarn start")
      assert_nil driver.send(:verify_cmd_specific_safe!, "git start")

      # Actual invocations of the cmd.exe start builtin must be blocked
      assert_raises(Rubik::Security::BlockedWriteError) do
        driver.send(:verify_cmd_specific_safe!, "start calc.exe")
      end
      assert_raises(Rubik::Security::BlockedWriteError) do
        driver.send(:verify_cmd_specific_safe!, "dir & start evil.exe")
      end
    end
  end

  def test_repl_allow_cmd_catastrophic_pattern_blocked_always
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)

    shell.execute_input('!allow-cmd "rm -rf /" --force')
    entries = shell.config.fetch("security.command_allowlist", [])
    refute_includes entries, "rm -rf /"
    assert_includes out.string, "matches a catastrophic destructive pattern"
  end

  # Regression for HIGH finding: the global classifier/allowlist check inside
  # ProcessDriver#verify_cmd_safe! must run BEFORE the cmd-specific approval, so
  # a cmd-specific construct can never re-authorize a command the classifier
  # rejected. If the two calls were ever swapped back (cmd-specific first),
  # approving verify_cmd_specific_safe! would let the command reach the spawn
  # path. The stub here makes verify_cmd_specific_safe! unconditionally approve,
  # so the only thing that can still reject is the classifier gate running first.
  def test_cmd_specific_cannot_authorize_classifier_rejected_command
    driver = Rubik::Sandbox::Driver::ProcessDriver.new
    mock_cmd = Struct.new(:classification, :argv, :inner_commands, :matched_rule, :classification_reason, :overriding_option, :command).new(:dangerous, ["node", "evil.js"], [], "node", "blocked by default rule: node", nil, ["node"])
    mock_ast = Struct.new(:classification, :commands, :parse_warnings).new(
      :dangerous,
      [mock_cmd],
      []
    )
    # The classifier refuses `node evil.js` (not allowlisted, dangerous).
    Rubik::Security::Classifier.stub :classify, mock_ast do
      # The cmd-specific approval is forced to always pass. If it ran before the
      # classifier, this would return [cmd] and reach the spawn path; the guard
      # gate must raise first.
      driver.stub :verify_cmd_specific_safe!, nil do
        assert_raises(Rubik::Security::BlockedWriteError) do
          driver.send(:verify_cmd_safe, "node evil.js")
        end
      end
    end
  end
end
