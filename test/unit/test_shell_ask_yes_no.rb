# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestShellAskYesNo < Minitest::Test
  FakeTTYInput = Object.new
  def FakeTTYInput.tty?
    true
  end

  # Non-StringIO output without test_capture? -> counts as interactive
  QuietOutput = Object.new
  def QuietOutput.puts(*); end
  def QuietOutput.print(*); end

  def build_shell(reline:, input: FakeTTYInput, output: QuietOutput)
    cfg_dir = Dir.mktmpdir("rubik_yn")
    home = Dir.mktmpdir("rubik_yn_home")
    shell = Rubik::REPL::Shell.new(
      config: Rubik::Config.new(root_dir: cfg_dir, home_dir: home),
      output: output, input: input, reline: reline, root_dir: cfg_dir
    )
    [shell, cfg_dir, home]
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@d1) if @d1 && File.exist?(@d1)
    FileUtils.remove_entry(@d2) if @d2 && File.exist?(@d2)
  end

  def with_env(key, value)
    old = ENV.fetch(key, nil)
    value ? ENV[key] = value : ENV.delete(key)
    yield
  ensure
    old ? ENV[key] = old : ENV.delete(key)
  end

  def test_non_interactive_short_circuits_to_default_without_reading
    reads = []
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) do |*a|
      reads << a
      "z"
    end
    @shell, @d1, @d2 = build_shell(reline: fake_reline, input: $stdin, output: StringIO.new)
    # RUBIK_TEST=1 is set by test_helper and StringIO output -> non-interactive
    assert_equal "n", @shell.ask_yes_no("Devam?", default: "n")
    assert_equal "y", @shell.ask_yes_no("Plan?", default: "y")
    assert_empty reads, "must not read input in non-interactive mode"
  end

  def test_interactive_reads_via_reline_and_normalizes_answer
    prompts = []
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) do |p, _hist|
      prompts << p
      "  Yes\n"
    end
    @shell, @d1, @d2 = build_shell(reline: fake_reline)
    with_env("RUBIK_TEST", nil) do
      assert_equal "yes", @shell.ask_yes_no("Devam edilsin mi?", default: "n")
      assert_equal "Devam edilsin mi? [y/N]: ", prompts.last
    end
  end

  def test_interrupt_during_prompt_returns_default_and_does_not_raise
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) { |_p, _h| raise Interrupt }
    @shell, @d1, @d2 = build_shell(reline: fake_reline, output: QuietOutput)
    with_env("RUBIK_TEST", nil) do
      assert_equal "n", @shell.ask_yes_no("X?", default: "n")
    end
  end

  def test_eof_returns_default
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) { |_p, _h| nil }
    @shell, @d1, @d2 = build_shell(reline: fake_reline)
    with_env("RUBIK_TEST", nil) do
      assert_equal "y", @shell.ask_yes_no("Plan?", default: "y")
    end
  end

  def test_bare_enter_selects_default_answer
    # The [Y/n] hint promises Enter = default; an empty line must not
    # fall through as "" (which call sites treat as "no").
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) { |_p, _h| "\n" }
    @shell, @d1, @d2 = build_shell(reline: fake_reline)
    with_env("RUBIK_TEST", nil) do
      assert_equal "y", @shell.ask_yes_no("Plan?", default: "y")
      assert_equal "n", @shell.ask_yes_no("Devam?", default: "n")
    end
  end

  def test_tee_io_wrapping_real_output_is_still_interactive
    # Production !plan runs with @output = TeeIO($stdout, captured StringIO);
    # the StringIO capture target must NOT make us short-circuit to the
    # default (that auto-approved plans without ever asking the user).
    reads = []
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) do |*a|
      reads << a
      "y"
    end
    File.open(File::NULL, "w") do |real_target|
      tee = Rubik::REPL::TeeIO.new(real_target, StringIO.new)
      @shell, @d1, @d2 = build_shell(reline: fake_reline, output: tee)
      with_env("RUBIK_TEST", nil) do
        assert_equal "y", @shell.ask_yes_no("Plan uygulansın mı?", default: "n")
        assert_equal 1, reads.size, "must READ via Reline when tee wraps real output"
      end
    end
  end

  def test_tee_io_with_only_stringio_targets_is_non_interactive
    reads = []
    fake_reline = Object.new
    fake_reline.define_singleton_method(:readline) do |*a|
      reads << a
      "y"
    end
    tee = Rubik::REPL::TeeIO.new(StringIO.new, StringIO.new)
    @shell, @d1, @d2 = build_shell(reline: fake_reline, output: tee)
    assert_equal "y", @shell.ask_yes_no("Plan?", default: "y")
    assert_equal "n", @shell.ask_yes_no("Devam?", default: "n")
    assert_empty reads, "test-harness tee (all StringIO) must not read input"
  end
end
