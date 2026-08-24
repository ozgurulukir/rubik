# frozen_string_literal: true

require_relative "../test_helper"

class TestWorkspaceCommand < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_ws_cmd_project")
    @temp_home = Dir.mktmpdir("rubik_ws_cmd_home")
    @extra_root1 = Dir.mktmpdir("rubik_ws_extra1")
    @extra_root2 = Dir.mktmpdir("rubik_ws_extra2")

    File.write(File.join(@extra_root1, "shared.rb"), "module Shared; end")
  end

  def teardown
    FileUtils.remove_entry(@temp_root) rescue nil
    FileUtils.remove_entry(@temp_home) rescue nil
    FileUtils.remove_entry(@extra_root1) rescue nil
    FileUtils.remove_entry(@extra_root2) rescue nil
  end

  def test_workspace_list_command
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!workspace list")
    assert_includes out.string, "=== Configured Workspace Roots ==="
    assert_includes out.string, "[PRIMARY] #{@temp_root} (Read-Write)"
    assert_includes out.string, "(No additional workspace roots configured)"
  end

  def test_workspace_add_and_persistence
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!workspace add #{@extra_root1} --project")
    assert_includes out.string, "[Rubik::Workspace] Added additional root: #{@extra_root1} (Mode: Read-Only)"
    assert_includes out.string, "[Project level (.rubik/config.yml)]"

    # Verify buffer manager has it
    assert_includes shell.buffer_manager.additional_roots, @extra_root1

    # Verify context index scanned it
    assert_includes shell.context_index.additional_roots, @extra_root1

    # Reload fresh config and verify persistence in project config
    reloaded_cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    saved_roots = reloaded_cfg.fetch("workspace.additional_roots")
    assert_includes saved_roots, @extra_root1
  end

  def test_workspace_add_with_rw_flag
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!workspace add #{@extra_root2} --rw")
    assert_includes out.string, "[Rubik::Workspace] Added additional root: #{@extra_root2} (Mode: Read-Write)"

    # Verify rw_roots
    assert_includes shell.buffer_manager.rw_roots, @extra_root2
  end

  def test_workspace_add_blocks_dangerous_system_root
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!workspace add /etc")
    assert_includes out.string, "Security Error"
    assert_includes out.string, "Adding dangerous system root as workspace is blocked"

    refute_includes shell.buffer_manager.additional_roots, "/etc"
  end

  def test_workspace_remove_and_persistence
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!workspace add #{@extra_root1} --project")
    assert_includes shell.buffer_manager.additional_roots, @extra_root1

    out.reopen
    shell.execute_input("!workspace remove #{@extra_root1} --project")
    assert_includes out.string, "[Rubik::Workspace] Removed additional root: #{@extra_root1}"

    refute_includes shell.buffer_manager.additional_roots, @extra_root1
    refute_includes shell.context_index.additional_roots, @extra_root1

    # Verify persistence
    reloaded_cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    saved_roots = reloaded_cfg.fetch("workspace.additional_roots")
    refute_includes saved_roots, @extra_root1
  end

  def test_roots_alias_command
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    shell.execute_input("!roots list")
    assert_includes out.string, "=== Configured Workspace Roots ==="
  end

  def test_config_set_scalar_array_parsing_and_sync
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    # Set array via !config set
    shell.execute_input("!config set workspace.additional_roots [\"#{@extra_root1}\"]")
    assert_includes out.string, "Config 'workspace.additional_roots' updated"

    assert_includes shell.buffer_manager.additional_roots, @extra_root1
    assert_includes shell.context_index.additional_roots, @extra_root1

    # Set allow_external_writes boolean via !config set
    out.reopen
    shell.execute_input("!config set workspace.allow_external_writes true")
    assert_equal true, shell.buffer_manager.allow_external_writes
  end

  def test_workspace_usage_and_relative_path
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out, root_dir: @temp_root)

    # Empty add command usage
    shell.execute_input("!workspace add")
    assert_includes out.string, "Usage: !workspace add <path>"

    # Empty remove command usage
    out.reopen
    shell.execute_input("!workspace remove")
    assert_includes out.string, "Usage: !workspace remove <path>"

    # Invalid subcommand
    out.reopen
    shell.execute_input("!workspace invalid_action")
    assert_includes out.string, "Usage: !workspace <list | add <path> [--rw] | remove <path>>"

    # Add relative path
    out.reopen
    rel_path = Pathname.new(@extra_root2).relative_path_from(Pathname.new(@temp_root)).to_s
    shell.execute_input("!workspace add #{rel_path}")
    assert_includes out.string, "[Rubik::Workspace] Added additional root: #{File.expand_path(@extra_root2)}"
  end
end
