# frozen_string_literal: true

require_relative "../test_helper"

class TestReplStandardizedCommands < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_std_project")
    @temp_home = Dir.mktmpdir("rubik_std_home")
    @out = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out)
  end

  def teardown
    FileUtils.remove_entry(@temp_root) rescue nil
    FileUtils.remove_entry(@temp_home) rescue nil
  end

  # =========================================================================
  # 1. Workspace / Config Commands
  # =========================================================================

  def test_config_explicit_verbs_and_guidance
    # 1.1 !config without args -> Usage
    @out.reopen
    @shell.execute_input("!config")
    assert_includes @out.string, "Usage: !config"

    # 1.2 !config path / paths
    @out.reopen
    @shell.execute_input("!config path")
    assert_includes @out.string, "Global Config"
    assert_includes @out.string, "Project Config"

    @out.reopen
    @shell.execute_input("!config paths")
    assert_includes @out.string, "Global Config"

    # 1.3 !config set <key> <val>
    @out.reopen
    @shell.execute_input("!config set agent.max_steps 55 --project")
    assert_includes @out.string, "Config 'agent.max_steps' updated to '55' [Project level (.rubik/config.yml)]."
    assert_equal 55, @shell.config.fetch("agent.max_steps")

    # 1.4 !config get <key>
    @out.reopen
    @shell.execute_input("!config get agent.max_steps")
    assert_includes @out.string, "agent.max_steps = 55"

    @out.reopen
    @shell.execute_input("!config get non_existent_key_xyz")
    assert_includes @out.string, "is not set or empty"

    # 1.5 !config list [filter]
    @out.reopen
    @shell.execute_input("!config list")
    assert_includes @out.string, "=== Rubik Configuration"
    assert_includes @out.string, "agent.max_steps"

    @out.reopen
    @shell.execute_input("!config list agent")
    assert_includes @out.string, "agent.max_steps"
    assert_includes @out.string, "agent.goal_max_steps"

    # 1.6 Verbless calls generate smart guidance
    @out.reopen
    @shell.execute_input("!config lsp.enabled true")
    assert_includes @out.string, "[Rubik::Config] Geçersiz kullanım."
    assert_includes @out.string, "• Ayar yapmak için : !config set lsp.enabled true"
    assert_includes @out.string, "• Değer okumak için: !config get lsp.enabled"

    @out.reopen
    @shell.execute_input("!config lsp.enabled")
    assert_includes @out.string, "[Rubik::Config] Geçersiz kullanım."
    assert_includes @out.string, "• Ayar yapmak için : !config set lsp.enabled <val>"
    assert_includes @out.string, "• Değer okumak için: !config get lsp.enabled"

    # 1.7 Subsystem wiring on !config set
    @out.reopen
    @shell.execute_input("!config set workspace.allow_external_writes true")
    assert_equal true, @shell.buffer_manager.allow_external_writes

    @out.reopen
    @shell.execute_input("!config set lsp.enabled false")
    assert_equal false, @shell.lsp_manager.enabled?
  end

  # =========================================================================
  # 2. LSP Commands
  # =========================================================================

  def test_lsp_subcommands_and_diagnostics
    # 2.1 !lsp status
    @out.reopen
    @shell.execute_input("!lsp status")
    assert_includes @out.string, "=== LSP Integration Status ==="
    assert_includes @out.string, "Configured Language Servers:"

    # 2.2 !lsp on / off
    @out.reopen
    @shell.execute_input("!lsp on")
    assert_includes @out.string, "LSP integration enabled"
    assert_equal true, @shell.config.fetch("lsp.enabled")

    @out.reopen
    @shell.execute_input("!lsp off")
    assert_includes @out.string, "LSP integration disabled"
    assert_equal false, @shell.config.fetch("lsp.enabled")

    # 2.3 !lsp servers
    @out.reopen
    @shell.execute_input("!lsp servers")
    assert_includes @out.string, "=== Supported & Configured Language Servers ==="
    assert_includes @out.string, "ruby"

    # 2.4 !lsp diag
    @out.reopen
    @shell.execute_input("!lsp diag")
    assert_includes @out.string, "No active LSP diagnostics"

    # 2.5 Standalone !diagnostics command
    @out.reopen
    @shell.execute_input("!diagnostics")
    assert_includes @out.string, "No active LSP diagnostics"

    # 2.6 !lsp start without lang
    @out.reopen
    @shell.execute_input("!lsp start")
    assert_includes @out.string, "Usage: !lsp start"

    # 2.7 !lsp stop
    @out.reopen
    @shell.execute_input("!lsp stop")
    assert_includes @out.string, "Stopped all active LSP servers."

    # 2.8 !lsp restart without running servers
    @out.reopen
    @shell.execute_input("!lsp restart")
    assert_includes @out.string, "No LSP servers are currently running."

    # 2.9 Invalid subcommand
    @out.reopen
    @shell.execute_input("!lsp unknown_sub")
    assert_includes @out.string, "Usage: !lsp <status | on | off | diag [file] | start <lang> | stop [lang] | restart [lang] | servers>"
  end

  # =========================================================================
  # 3. Buffer Commands (!diff, !apply, !undo, !rollback, !autoapply)
  # =========================================================================

  def test_buffer_commands
    # 3.1 !diff with clean buffer
    @out.reopen
    @shell.execute_input("!diff")
    assert_includes @out.string, "No unapplied buffer changes."

    # Modify a file in buffer
    @shell.buffer_manager.write("test_file.rb", "puts 'hello world'\n")

    # 3.2 !diff (all and specific path)
    @out.reopen
    @shell.execute_input("!diff")
    assert_includes @out.string, "+puts 'hello world'"

    @out.reopen
    @shell.execute_input("!diff test_file.rb")
    assert_includes @out.string, "+puts 'hello world'"

    @out.reopen
    @shell.execute_input("!diff other_file.rb")
    assert_includes @out.string, "No unapplied buffer changes for 'other_file.rb'."

    # 3.3 !apply specific file
    @out.reopen
    @shell.execute_input("!apply test_file.rb")
    assert_includes @out.string, "Applied changes to file: test_file.rb"
    assert File.exist?(File.join(@temp_root, "test_file.rb"))
    assert_equal "puts 'hello world'\n", File.read(File.join(@temp_root, "test_file.rb"))
    refute @shell.buffer_manager.dirty?

    # 3.4 !undo
    @out.reopen
    @shell.execute_input("!undo")
    assert_includes @out.string, "No snapshots to undo."

    # 3.5 !rollback without arg -> Usage
    @out.reopen
    @shell.execute_input("!rollback")
    assert_includes @out.string, "Usage: !rollback <snapshot_id>"

    @out.reopen
    @shell.execute_input("!rollback non_existent_snap")
    assert_includes @out.string, "Snapshot non_existent_snap not found."

    # 3.6 !autoapply
    @out.reopen
    @shell.execute_input("!autoapply status")
    assert_includes @out.string, "Buffer Auto-Apply Policy:"

    @out.reopen
    @shell.execute_input("!autoapply always --project")
    assert_includes @out.string, "Buffer auto-apply policy set to 'always' [Project level (.rubik/config.yml)]."
    assert_equal "always", @shell.config.fetch("buffer.auto_apply")

    @out.reopen
    @shell.execute_input("!autoapply invalid_mode")
    assert_includes @out.string, "Usage: !autoapply <manual | on_test | on_finish | always | status>"
  end

  # =========================================================================
  # 4. Session Commands (!session save, list, info, resume)
  # =========================================================================

  def test_session_commands
    # 4.1 !session info
    @out.reopen
    @shell.execute_input("!session info")
    assert_includes @out.string, "Active Session File:"
    assert_includes @out.string, "Total Events in Session:"

    # 4.2 !session list
    @out.reopen
    @shell.execute_input("!session list")
    assert(
      @out.string.include?("Recorded Sessions") ||
      @out.string.include?("No recorded sessions found")
    )

    # 4.3 !session save without arg
    @out.reopen
    @shell.execute_input("!session save")
    assert_includes @out.string, "Usage: !session save <name>"

    # 4.4 !session save <name>
    @shell.recorder.record_user_turn("Hello Rubik session test")
    @out.reopen
    @shell.execute_input("!session save my_named_session")
    assert_includes @out.string, "[Rubik::Session] Session saved to"
    assert_includes @out.string, "my_named_session.jsonl"

    saved_file = File.join(@temp_root, ".rubik", "sessions", "my_named_session.jsonl")
    assert File.exist?(saved_file)
    content = File.read(saved_file)
    assert_includes content, "Hello Rubik session test"

    # 4.5 Invalid subcommand
    @out.reopen
    @shell.execute_input("!session bogus")
    assert_includes @out.string, "Usage: !session <list | resume [id] | save <name> | info>"
  end

  # =========================================================================
  # 5. Agent Commands (!steps, !context)
  # =========================================================================

  def test_steps_subcommands
    # 5.1 !steps status
    @out.reopen
    @shell.execute_input("!steps status")
    assert_includes @out.string, "=== Agentic Step Budget Configuration ==="

    # 5.2 !steps default <n>
    @out.reopen
    @shell.execute_input("!steps default 45")
    assert_includes @out.string, "Agent default max steps set to 45"
    assert_equal 45, @shell.config.fetch("agent.max_steps")

    # 5.3 !steps goal <n>
    @out.reopen
    @shell.execute_input("!steps goal 90")
    assert_includes @out.string, "Goal mode max steps set to 90"
    assert_equal 90, @shell.config.fetch("agent.goal_max_steps")

    # 5.4 !steps plan <n>
    @out.reopen
    @shell.execute_input("!steps plan 20")
    assert_includes @out.string, "Plan mode max steps set to 20"
    assert_equal 20, @shell.config.fetch("agent.plan_max_steps")

    # 5.5 !steps <n>
    @out.reopen
    @shell.execute_input("!steps 30")
    assert_includes @out.string, "Agent default max steps set to 30"
    assert_equal 30, @shell.config.fetch("agent.max_steps")

    # 5.6 !steps invalid
    @out.reopen
    @shell.execute_input("!steps invalid_arg")
    assert_includes @out.string, "Usage: !steps [status | default <number> | goal <number> | plan <number> | <number>]"
  end

  def test_context_subcommands
    # 5.7 !context status
    @out.reopen
    @shell.execute_input("!context status")
    assert_includes @out.string, "=== LLM Context Window & In-Memory Status ==="

    # 5.8 !context stats
    @out.reopen
    @shell.execute_input("!context stats")
    assert_includes @out.string, "=== Context & Token Statistics ==="
    assert_includes @out.string, "Context Limit"
    assert_includes @out.string, "Consumed Tokens"

    # 5.9 !context compact
    @out.reopen
    @shell.execute_input("!context compact")
    assert_includes @out.string, "Context compaction completed"

    # 5.10 !context scan
    @out.reopen
    @shell.execute_input("!context scan")
    assert_includes @out.string, "Context index and AST symbol graph updated."

    # 5.11 !context invalid
    @out.reopen
    @shell.execute_input("!context xyz")
    assert_includes @out.string, "Usage: !context <status | compact | stats | scan | add <file> | drop <file>>"
  end
end
