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
    File.write(File.join(@temp_dir, "sample.rb"), "def sample; end")
    @shell.execute_input("!context scan")
    out = @output.string
    assert_includes out, "Context index and AST symbol graph updated."
  end

  def test_context_scan_empty_root_says_so_instead_of_success
    # An empty scan result must not report success.
    @shell.execute_input("!context scan")
    out = @output.string
    assert_includes out, "produced NO indexed files"
    refute_includes out, "updated."
  end

  def test_context_add_and_drop_subcommands
    test_file = "lib/sample.rb"
    begin
      File.write(File.join(@temp_dir, test_file), "def sample; end")
    rescue StandardError
      nil
    end

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

  # --- Partial-scan honesty (#357) ---

  def test_scan_reports_partial_when_the_scan_aborted
    # Non-empty + aborted: one subtree blows up mid-walk while a root file
    # survives — the index is usable but must not read as complete.
    File.write(File.join(@temp_dir, "sample.rb"), "def sample; end")
    FileUtils.mkdir_p(File.join(@temp_dir, "sub"))
    File.write(File.join(@temp_dir, "sub", "inner.rb"), "def inner; end")
    scanner = @shell.context_index.scanner
    scanner.define_singleton_method(:subtree_ignored?) do |dir_rel, needles|
      raise "forced walk failure" if dir_rel == "sub"

      Rubik::Context::Scanner::HARD_PRUNE_ROOTS.include?(dir_rel.split("/").first) ||
        needles.any? { |n| dir_rel.split("/") == n }
    end

    @shell.execute_input("!context scan")
    out = @output.string

    assert_includes out, "finished PARTIALLY"
    assert_includes out, "forced walk failure"
    refute_includes out, "updated."
  end

  def test_clean_scan_output_stays_byte_identical
    File.write(File.join(@temp_dir, "sample.rb"), "def sample; end")
    @shell.execute_input("!context scan")

    out = @output.string

    assert_includes out, "Context index and AST symbol graph updated."
    refute_includes out, "PARTIAL"
  end

  def test_status_and_stats_show_partial_flag_only_after_an_abort
    File.write(File.join(@temp_dir, "sample.rb"), "def sample; end")
    @shell.context_index.full_scan

    @shell.execute_input("!context status")
    @shell.execute_input("!context stats")
    refute_includes @output.string, "PARTIAL", "a clean index must not display the flag"

    scanner = @shell.context_index.scanner
    scanner.define_singleton_method(:scan_root) { |*_args| raise "boom" }
    @shell.context_index.full_scan
    scanner.singleton_class.send(:remove_method, :scan_root)

    @shell.execute_input("!context status")
    @shell.execute_input("!context stats")
    out = @output.string

    assert_includes out, "PARTIAL"
    assert_includes out, "boom"
  end

  # --- Huge-root guidance (#356) ---

  def test_boot_in_home_root_prints_one_notice_and_skips_the_boot_scan
    with_rubik_test_env do
      File.write(File.join(@temp_home, "home_file.rb"), "def f; end")
      home_config = Rubik::Config.new(root_dir: @temp_home, home_dir: @temp_home)
      home_output = StringIO.new
      home_shell = Rubik::REPL::Shell.new(config: home_config,
                                          buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_home),
                                          output: home_output)
      begin
        assert_equal 1, home_output.string.scan("huge tree").length,
                     "exactly ONE guidance notice at boot"
        assert_equal 0, home_shell.context_index.status_summary[:file_count],
                     "strong huge-root signal skips the boot warm walk"
      ensure
        home_shell.stop
      end

      # The explicit scan is the opt-in: the home shell must not print a
      # second notice (memoized), even after scanning.
      home_shell.execute_input("!context scan")

      assert_equal 1, home_output.string.scan("huge tree").length
    end
  end

  def test_boot_scan_on_huge_root_knob_restores_the_boot_walk
    with_rubik_test_env do
      File.write(File.join(@temp_home, "home_file.rb"), "def f; end")
      home_config = Rubik::Config.new(root_dir: @temp_home, home_dir: @temp_home)
      home_config.set("context.boot_scan_on_huge_root", true)
      home_shell = Rubik::REPL::Shell.new(config: home_config,
                                          buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_home),
                                          output: @output)
      begin
        assert home_shell.context_index.status_summary[:file_count].positive?,
               "the knob opts back into the boot warm walk"
      ensure
        home_shell.stop
      end
    end
  end

  def test_ordinary_repo_boot_prints_no_huge_root_notice
    with_rubik_test_env do
      FileUtils.mkdir_p(File.join(@temp_dir, ".git"))
      File.write(File.join(@temp_dir, "proj.rb"), "def p; end")
      repo_config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
      repo_output = StringIO.new
      repo_shell = Rubik::REPL::Shell.new(config: repo_config,
                                          buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir),
                                          output: repo_output)
      begin
        repo_shell.execute_input("!context status")
        refute_includes repo_output.string, "huge tree", "normal-repo boot/output stays quiet"
      ensure
        repo_shell.stop
      end
    end
  end

  private

  # Pins the env-aware async knobs to their synchronous test posture so
  # boot-scan assertions are deterministic when run outside rake.
  def with_rubik_test_env
    was = ENV.fetch("RUBIK_TEST", nil)
    ENV["RUBIK_TEST"] = "1"
    yield
  ensure
    ENV["RUBIK_TEST"] = was
  end
end
