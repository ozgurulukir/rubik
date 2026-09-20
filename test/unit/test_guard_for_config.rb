# frozen_string_literal: true

require_relative "../test_helper"

# Guard unification (Plan: guard-policy-unification, 2026-09-20) — the ONE
# composed, config-derived, live-reconfigurable Guard must reach every
# verification path: composition (Guard.for_config), buffer manager, sandbox
# Runner → ProcessDriver (Windows cmd.exe re-verification), MCP spawn gate,
# RunTestsTool synthesis gate and GenericAdapter validation.
class TestGuardForConfig < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_guard_for_config")
    @tmp_outside = Dir.mktmpdir("rubik_chdir_outside")
    @audit = File.join(@tmp, "audit.log")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
    FileUtils.remove_entry(@tmp_outside) if @tmp_outside && File.directory?(@tmp_outside)
  rescue StandardError
    nil
  end

  def config_with_security(allowlist: [], probes: true, audit: @audit)
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    cfg.set("security.command_allowlist", allowlist, persist: false) unless allowlist.empty?
    cfg.set("security.allow_safe_probes", probes, persist: false) unless probes == true
    # Always set explicitly: an explicit nil must disable auditing, while an
    # unset key falls back to the config's merged default path.
    cfg.set("security.audit_log_path", audit, persist: false)
    cfg
  end

  # (a) Equivalence: for_config reproduces the composed shell guard's policy
  # surface AND its verdicts on the same commands.
  def test_for_config_matches_composed_shell_guard_policy
    cfg = config_with_security(allowlist: ["node .gitnexus/run.cjs"], probes: "false")
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @tmp)
    factory_guard = Rubik::Security::Guard.for_config(cfg)

    assert_equal shell.guard.command_allowlist, factory_guard.command_allowlist
    assert_equal shell.guard.allow_safe_probes?, factory_guard.allow_safe_probes?
    assert_equal shell.guard.audit_log_path, factory_guard.audit_log_path

    # Verdict parity on: allowlisted pass, non-allowlisted dangerous block,
    # catastrophic block regardless of allowlist.
    assert factory_guard.verify_command_safety!("node .gitnexus/run.cjs status")
    [shell.guard, factory_guard].each do |g|
      assert_raises(Rubik::Security::BlockedWriteError) { g.verify_command_safety!("node evil.js") }
      assert_raises(Rubik::Security::BlockedWriteError) { g.verify_command_safety!("mkfs /dev/sda") }
    end
  end

  # (f) Explicit nil audit path disables auditing (the old composition call
  # site's `fetch(...) || default` silently re-enabled it).
  def test_for_config_explicit_nil_audit_path_disables
    cfg = config_with_security(audit: nil)
    guard = Rubik::Security::Guard.for_config(cfg)

    assert_nil guard.audit_log_path
    assert_raises(Rubik::Security::BlockedWriteError) { guard.verify_command_safety!("node evil.js") }
  end

  def test_for_config_blank_audit_path_disables
    cfg = config_with_security(audit: "  ")
    guard = Rubik::Security::Guard.for_config(cfg)

    assert_nil guard.audit_log_path
  end

  # Config's scalar parser turns `!config set security.audit_log_path false`
  # into boolean false — a non-path value must disable auditing VISIBLY (warn)
  # rather than die in a swallowed TypeError inside log_audit.
  def test_for_config_non_path_audit_value_disables_with_warning
    cfg = config_with_security(audit: false)
    guard = Rubik::Security::Guard.for_config(cfg)

    assert_nil guard.audit_log_path
    assert_raises(Rubik::Security::BlockedWriteError) { guard.verify_command_safety!("node evil.js") }
  end

  # Live reconfiguration: the audit destination moves mid-session (nil/blank
  # disables) via Guard#audit_log_path= + ConfigWiring.
  def test_audit_log_path_is_live_reconfigurable
    guard = Rubik::Security::Guard.new(audit_log_path: @audit)
    new_path = File.join(@tmp, "audit2.log")

    guard.audit_log_path = new_path
    assert_raises(Rubik::Security::BlockedWriteError) { guard.verify_command_safety!("node evil.js") }
    assert File.exist?(new_path), "audit must flow to the reconfigured path"

    guard.audit_log_path = ""
    assert_nil guard.audit_log_path
  end

  def test_for_config_absent_key_uses_default_audit_path
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    guard = Rubik::Security::Guard.for_config(cfg)

    assert_equal Rubik::Security::Guard.default_audit_log_path, guard.audit_log_path
  end

  def test_for_config_with_nil_or_non_config_object
    assert_equal Rubik::Security::Guard.new.audit_log_path, Rubik::Security::Guard.for_config(nil).audit_log_path
    assert_equal Rubik::Security::Guard.new.command_allowlist, Rubik::Security::Guard.for_config("nope").command_allowlist
  end

  # One instance everywhere: buffer manager, sandbox runner, MCP manager and
  # task manager hold the exact object composition built, so live !allow-cmd
  # mutation reaches them.
  def test_composition_shares_one_guard_across_consumers
    cfg = config_with_security(allowlist: ["node .gitnexus/run.cjs"])
    parts = Rubik::REPL::Composition.build(config: cfg)

    assert_equal parts.guard, parts.buffer_manager.guard
    assert_equal parts.guard, parts.sandbox_runner.guard
    assert_equal parts.guard, parts.mcp_manager.guard
    assert_equal parts.guard, parts.task_manager.guard
  end

  # (b) Windows regression: the ProcessDriver cmd.exe spawn gate consults the
  # INJECTED session guard, so an allowlisted command approved by
  # RunCommandTool is not re-blocked by an empty-allowlist private guard.
  def test_process_driver_honors_injected_guard_allowlist_on_cmd_branch
    shared = Rubik::Security::Guard.new(command_allowlist: ["node .gitnexus/run.cjs"], audit_log_path: @audit)
    driver = Rubik::Sandbox::Driver::ProcessDriver.new(guard: shared)

    Rubik::Platform.stub :windows?, true do
      assert_equal ["node .gitnexus/run.cjs"], driver.send(:verify_cmd_safe, "node .gitnexus/run.cjs")
      assert_raises(Rubik::Security::BlockedWriteError) do
        driver.send(:verify_cmd_safe, "node evil.js")
      end
    end

    # Standalone driver without injection keeps today's fail-closed fallback.
    bare = Rubik::Sandbox::Driver::ProcessDriver.new
    Rubik::Platform.stub :windows?, true do
      assert_raises(Rubik::Security::BlockedWriteError) do
        bare.send(:verify_cmd_safe, "node .gitnexus/run.cjs")
      end
    end
  end

  # reconfigure! rebuilds drivers on every sandbox.* config change — the
  # injected guard must ride along in driver_opts every time.
  def test_runner_reconfigure_keeps_injected_guard
    shared = Rubik::Security::Guard.new(command_allowlist: [], audit_log_path: @audit)
    cfg = Rubik::Config.new(root_dir: @tmp, home_dir: File.join(@tmp, "home"))
    runner = Rubik::Sandbox::Runner.new(root_dir: @tmp, config: cfg, guard: shared)

    cfg.set("sandbox.timeout_seconds", 20, persist: false) # fires on_change("sandbox") → reconfigure!

    host_driver = runner.instance_variable_get(:@host_driver)
    assert_equal shared, host_driver.send(:guard)
  end

  # (d) Chdir blocks carry structured kind:/path:; blocked_guidance renders the
  # !allow-dir hint from the field instead of regex-munging the message.
  def test_chdir_block_carries_kind_and_path_and_guidance_uses_field
    runner = Rubik::Sandbox::Runner.new(root_dir: @tmp)
    outside = File.join(@tmp_outside, "dir")

    err = assert_raises(Rubik::Security::BlockedWriteError) { runner.verify_chdir_safety!(outside) }
    assert_equal :chdir_outside_root, err.kind
    assert_equal File.expand_path(outside, @tmp), err.path

    guidance = Rubik::Tools::RunCommandTool.blocked_guidance(err)
    assert guidance.start_with?("Security blocked: ")
    assert_includes guidance, "!allow-dir add \"#{err.path}\""
    refute_includes guidance, "!allow-cmd"
  end

  # (c) MCP block: exactly ONE audit line, written by the guard with the true
  # reason — the deleted manual entry used to double-log a mislabeled copy.
  def test_mcp_block_writes_exactly_one_audit_line
    guard = Rubik::Security::Guard.new(audit_log_path: @audit)
    transport = Rubik::MCP::Transport::Stdio.new("node", args: ["definitely-not-allowlisted.js"],
                                                         root_dir: @tmp, guard: guard)

    assert_raises(Rubik::MCP::ConnectionError) { transport.open }

    lines = File.readlines(@audit).map { |l| JSON.parse(l) }
    blocked = lines.select { |e| e["action"] == "blocked_command" }
    assert_equal 1, blocked.size
    assert_equal "node definitely-not-allowlisted.js", blocked.first["details"]["command"]
    refute_empty blocked.first["details"]["reason"]
  end

  def test_mcp_regex_fallback_block_also_writes_exactly_one_audit_line
    guard = Rubik::Security::Guard.new(audit_log_path: File.join(@tmp, "audit_regex.log"))
    transport = Rubik::MCP::Transport::Stdio.new("mkfs /dev/sda", root_dir: @tmp, guard: guard)

    assert_raises(Rubik::MCP::ConnectionError) { transport.open }

    blocked = File.readlines(File.join(@tmp, "audit_regex.log")).map { |l| JSON.parse(l) }
                  .select { |e| e["action"] == "blocked_command" }
    assert_equal 1, blocked.size
  end

  def test_mcp_client_forwards_guard_to_stdio_transport
    guard = Rubik::Security::Guard.new(audit_log_path: @audit)
    client = Rubik::MCP::Client.new("node", args: ["x"], root_dir: @tmp, guard: guard)

    assert_equal guard, client.transport.instance_variable_get(:@guard)
  end

  # (e) run_tests: an operator-allowlisted interpreter runner passes the
  # synthesis gate (previously re-blocked by a fresh empty-allowlist guard),
  # and the synthesized GenericAdapter shares the same guard object.
  def test_run_tests_allowlisted_runner_command_passes_synthesis_gate
    cfg = config_with_security(allowlist: ["python3 -m pytest"])
    cfg.set("test.runners.python", "python3 -m pytest", persist: false)
    shared = Rubik::Security::Guard.for_config(cfg)
    tool = Rubik::Tools::RunTestsTool.new(Rubik::Adapter::Registry.new, nil, root_dir: @tmp, config: cfg, guard: shared)

    adapter = tool.send(:synthesize_adapter, "python")

    assert_instance_of Rubik::Adapter::GenericAdapter, adapter
    assert_equal shared, adapter.instance_variable_get(:@validation_guard)

    # Negative: without the allowlist the same candidate is blocked fail-closed.
    plain_cfg = config_with_security(allowlist: [])
    plain_cfg.set("test.runners.python", "python3 -m pytest", persist: false)
    plain_tool = Rubik::Tools::RunTestsTool.new(Rubik::Adapter::Registry.new, nil, root_dir: @tmp, config: plain_cfg)
    assert_raises(Rubik::Security::BlockedWriteError) do
      plain_tool.send(:synthesize_adapter, "python")
    end
  end
end
