# frozen_string_literal: true

require_relative "../test_helper"

class TestReplCommandDecoupling < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @shell = Rubik::REPL::Shell.new(
      config: @config,
      buffer_manager: @buffer_manager,
      output: @output
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_base_parse_scope_helper
    scope, clean = Rubik::REPL::Commands::Base.parse_scope(["status", "--project"])
    assert_equal :project, scope
    assert_equal ["status"], clean

    scope_short, clean_short = Rubik::REPL::Commands::Base.parse_scope(["-p", "set", "foo"])
    assert_equal :project, scope_short
    assert_equal %w[set foo], clean_short

    scope_glob, clean_glob = Rubik::REPL::Commands::Base.parse_scope(["--global", "on"])
    assert_equal :global, scope_glob
    assert_equal ["on"], clean_glob

    scope_def, clean_def = Rubik::REPL::Commands::Base.parse_scope(["manual"])
    assert_equal :global, scope_def
    assert_equal ["manual"], clean_def
  end

  def test_all_six_domain_modules_exist
    expected_modules = [
      Rubik::REPL::Commands::System,
      Rubik::REPL::Commands::Buffer,
      Rubik::REPL::Commands::Session,
      Rubik::REPL::Commands::Workspace,
      Rubik::REPL::Commands::Lsp,
      Rubik::REPL::Commands::Agent
    ]
    assert_equal expected_modules, Rubik::REPL::Commands::MODULES
  end

  def test_all_expected_commands_registered
    expected_commands = %w[
      help commands runtime fibers services quit exit clear reset status
      diff apply undo rollback autoapply
      history replay session
      workspace roots config
      lsp symbols outline refs ast
      plan goal steps verbosity verbose provider providers model context test lint format sh
    ]

    expected_commands.each do |cmd|
      assert @shell.commands.key?(cmd), "Expected shell to have command '!#{cmd}' registered"
    end
  end

  def test_shell_line_count_and_clean_dispatch
    shell_file = File.expand_path("../../lib/rubik/repl/shell.rb", __dir__)
    lines = File.readlines(shell_file).size
    assert lines < 550, "Expected shell.rb to be decoupled and under 550 lines, got #{lines} lines"
  end
end
