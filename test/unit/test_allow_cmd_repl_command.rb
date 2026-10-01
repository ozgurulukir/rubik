# frozen_string_literal: true

require_relative "../test_helper"

# Plan: komut-allowlist-güvenlik-kapısı (2026-09-14) — Paket B/D kilidi.
# Operator-only !allow-cmd REPL workflow + agent self-allowlist prohibition.
class TestAllowCmdReplCommand < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_allowcmd_test")
    @out = StringIO.new
    @cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    @shell = Rubik::REPL::Shell.new(config: @cfg, output: @out, root_dir: @tmp)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
  rescue StandardError
    nil
  end

  def test_allow_cmd_add_list_remove_workflow
    @shell.execute_input('!allow-cmd add "node .gitnexus/run.cjs" --project')
    assert_includes @out.string, "[Rubik::AllowCmd] Added command prefix: node .gitnexus/run.cjs"
    assert_equal ["node .gitnexus/run.cjs"], @shell.config.fetch("security.command_allowlist")

    @out.reopen
    @shell.execute_input("!allow-cmd list")
    assert_includes @out.string, "node .gitnexus/run.cjs"

    @out.reopen
    @shell.execute_input('!allow-cmd remove "node .gitnexus/run.cjs"')
    assert_includes @out.string, "Removed command prefix"
    assert_equal [], @shell.config.fetch("security.command_allowlist")
  end

  def test_added_prefix_takes_effect_on_guard_immediately
    @shell.execute_input('!allow-cmd add "node .gitnexus/run.cjs"')
    assert @shell.guard.verify_command_safety!("node .gitnexus/run.cjs status")

    @out.reopen
    @shell.execute_input('!allow-cmd remove "node .gitnexus/run.cjs"')
    assert_raises(Rubik::Security::BlockedWriteError) do
      @shell.guard.verify_command_safety!("node .gitnexus/run.cjs status")
    end
  end

  def test_broad_dangerous_entry_requires_force
    @shell.execute_input("!allow-cmd add \"node\"")
    assert_includes @out.string, "Blocked:"
    assert_equal [], @shell.config.fetch("security.command_allowlist")

    # Fix (Cluster A): even with --force a broad single-token dangerous entry
    # is blocked — it grants unbounded command execution (e.g. `node -e '...'` RCE).
    @out.reopen
    @shell.execute_input("!allow-cmd add \"node\" --force")
    assert_equal [], @shell.config.fetch("security.command_allowlist")
    assert_includes @out.string, "broad, single-token dangerous command"
  end

  def test_classifier_crash_fails_closed_on_broad_token_check
    # G3 triage Priority-1: a classifier crash used to fail OPEN (broad=false,
    # check skipped). It must fail closed — treat as broad, warn, block.
    classifier_raised = ->(_token) { raise "classifier exploded" }
    Rubik::Security::Classifier.stub(:classify, classifier_raised) do
      assert_output(nil, /classifier failed for 'node'/) do
        @shell.execute_input("!allow-cmd add \"node\" --force")
      end
    end

    assert_equal [], @shell.config.fetch("security.command_allowlist"),
                 "crashed classifier must not allowlist a broad token"
    assert_includes @out.string, "broad, single-token dangerous command"
  end

  def test_broad_dangerous_entry_narrow_prefix_with_force_succeeds
    @out.reopen
    @shell.execute_input("!allow-cmd add \"node .gitnexus/run.cjs\" --force")
    assert_includes @out.string, "[Rubik::AllowCmd] Added command prefix: node .gitnexus/run.cjs"
  end

  # Paket D: the model cannot self-allowlist via !config (agent_caller proof).
  def test_agent_cannot_set_security_namespace_via_config
    @shell.agent_caller = true
    @shell.execute_input("!config set security.command_allowlist node evil.js")
    refute_includes @out.string, "updated to"
    assert_includes @out.string, "Security Error"
    assert_equal [], @shell.config.fetch("security.command_allowlist")
  ensure
    @shell.agent_caller = false
  end

  def test_agent_cannot_toggle_sandbox_namespace_via_config
    @shell.agent_caller = true
    @shell.execute_input("!config set sandbox.enabled true")
    refute_includes @out.string, "updated to"
    assert_includes @out.string, "Security Error"
    assert_equal false, @shell.config.fetch("sandbox.enabled")
  ensure
    @shell.agent_caller = false
  end

  # Maestro kapısı canlı config okur — ajan kendi tasmasını çözemez:
  # subagents.* operatör-only (yoksa "!config set subagents.maestro_gate
  # false" tek çağrıyla gate'i devre dışı bırakırdı).
  def test_agent_cannot_toggle_subagents_namespace_via_config
    @shell.agent_caller = true
    @shell.execute_input("!config set subagents.maestro_gate false")
    refute_includes @out.string, "updated to"
    assert_includes @out.string, "Security Error"
    assert_equal true, @shell.config.fetch("subagents.maestro_gate")
  ensure
    @shell.agent_caller = false
  end

  # Human operator keeps full config access — the restriction is caller-scoped.
  def test_human_can_still_set_security_namespace_via_config
    @shell.execute_input("!config set security.audit_log_path #{File.join(@tmp, 'audit2.log')}")
    assert_includes @out.string, "updated to"
  end

  # Fail-closed: agent cannot invoke !allow-cmd at all (audience :human).
  def test_agent_cannot_invoke_allow_cmd_via_exec_repl_command
    registry = Rubik::Tools::Registry.new
    registry.register(Rubik::Tools::ExecReplCommandTool.new(@shell))
    result = registry.get("exec_repl_command").execute("command" => '!allow-cmd add "node evil.js"')

    assert_includes result, "reserved for the human operator"
    assert_equal [], @shell.config.fetch("security.command_allowlist")
  end

  # Reactive wiring (Paket B): config change reaches the live guard.
  def test_config_on_change_rewires_live_guard
    @cfg.set("security.command_allowlist", ["git push"])
    assert_equal [["git", "push"]], @shell.guard.command_allowlist
  end
end
