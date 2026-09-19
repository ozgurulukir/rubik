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
    actions = File.readlines(@audit).filter_map { |l| (JSON.parse(l)["action"] rescue nil) }
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

    actions = File.readlines(@audit).filter_map { |l| (JSON.parse(l)["action"] rescue nil) }
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
end
