# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "tmpdir"
require "fileutils"

class TestConfigAgentSecurity < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik-sec-root-")
    @temp_home = Dir.mktmpdir("rubik-sec-home-")
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_root) if @temp_root && File.directory?(@temp_root)
    FileUtils.remove_entry_secure(@temp_home) if @temp_home && File.directory?(@temp_home)
  end

  def test_agent_caller_blocked_from_operator_only_configuration_keys
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    cmd_handler = shell.commands["config"][:handler]

    # Create an agent context (agent_caller: true)
    shell.agent_caller = true
    agent_ctx = Rubik::REPL::CommandContext.new(shell)

    blocked_keys = [
      "security.command_allowlist",
      "sandbox.enabled",
      "subagents.max_concurrency",
      "plugins.load",
      "lsp.servers.ruby.command",
      "workspace.allow_external_writes",
      "tools.circuit_breaker.threshold"
    ]

    blocked_keys.each do |key|
      out.reopen
      cmd_handler.call(["set", key, "exploit_value"], agent_ctx)
      assert_includes out.string, "Security Error", "Expected '#{key}' to be blocked for agent callers"
      assert_includes out.string, "operator-only"
    end
  end

  def test_agent_caller_allowed_to_modify_safe_session_keys
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    cmd_handler = shell.commands["config"][:handler]
    shell.agent_caller = true
    agent_ctx = Rubik::REPL::CommandContext.new(shell)

    out.reopen
    cmd_handler.call(["set", "ui.verbosity", "verbose"], agent_ctx)
    refute_includes out.string, "Security Error"
    assert_includes out.string, "Config 'ui.verbosity' updated to 'verbose'"
    assert_equal "verbose", cfg.fetch("ui.verbosity")
  end

  def test_human_operator_can_modify_all_configuration_keys
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    cmd_handler = shell.commands["config"][:handler]
    # Human operator context (agent_caller: false)
    shell.agent_caller = false
    human_ctx = Rubik::REPL::CommandContext.new(shell)

    out.reopen
    cmd_handler.call(["set", "workspace.allow_external_writes", "true"], human_ctx)
    refute_includes out.string, "Security Error"
    assert_includes out.string, "Config 'workspace.allow_external_writes' updated to 'true'"
    assert_equal true, cfg.fetch("workspace.allow_external_writes")
  end
end
