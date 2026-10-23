# frozen_string_literal: true

require_relative "../test_helper"

class TestREPLAgentContextCommand < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(
      config: @config,
      buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir),
      output: @output
    )
  end

  def teardown
    @shell.stop
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def test_context_status_subcommand
    @shell.execute_input("!context status")
    out = @output.string
    assert_includes out, "=== LLM Context Window & In-Memory Status ==="
    assert_includes out, "Active Model:"
    assert_includes out, "Usable Input Ceiling:"
  end

  def test_context_default_subcommand_is_status
    @shell.execute_input("!context")
    out = @output.string
    assert_includes out, "=== LLM Context Window & In-Memory Status ==="
  end

  def test_context_stats_subcommand
    @shell.execute_input("!context stats")
    out = @output.string
    assert_includes out, "=== Context & Token Statistics ==="
    assert_includes out, "Consumed Tokens"
  end

  def test_context_compact_subcommand
    @shell.execute_input("!context compact")
    out = @output.string
    assert_includes out, "Context compaction completed:"
  end

  def test_context_scan_subcommand
    @shell.execute_input("!context scan")
    out = @output.string
    assert_includes out, "Context index and AST symbol graph updated."
  end

  def test_context_add_and_drop_subcommands
    test_file = "lib/sample.rb"
    File.write(File.join(@temp_dir, test_file), "def sample; end") rescue nil

    @shell.execute_input("!context add #{test_file}")
    out = @output.string
    assert_includes out, "Added #{test_file} to context index and AST graph."

    @output.truncate(0)
    @output.rewind

    @shell.execute_input("!context drop #{test_file}")
    out2 = @output.string
    assert_includes out2, "Removed #{test_file} from context index."
  end

  def test_context_drop_without_argument
    @shell.execute_input("!context drop")
    out = @output.string
    assert_includes out, "Usage: !context drop <relative_file_path>"
  end

  def test_context_unknown_subcommand
    @shell.execute_input("!context invalid_subcommand")
    out = @output.string
    assert_includes out, "Usage: !context <status | compact | stats | scan | add <file> | drop <file>>"
  end
end
