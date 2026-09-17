# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Plan 91 — Multi-line paste desteği birim testleri.
class TestPasteSupport < Minitest::Test
  def setup
    # root_dir/home_dir gerekli: RUBIK_TEST=1 async warm-up'ı kapatır; rootsuz
    # shell senkron olarak tüm rubik repo'sunu indeksler (~6s/test -> suite
    # timeout görünümü). Konvansiyon: izole tmpdir (bkz. test_repl'den farklı,
    # test_cancelled_turn_recording ile aynı kalıp).
    @temp_dir = Dir.mktmpdir("rubik_paste_test")
    @temp_home = Dir.mktmpdir("rubik_paste_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def executed_shell(lines, clock)
    executed = []
    @shell.define_singleton_method(:execute_input) { |text| executed << text }
    @shell.define_singleton_method(:paste_clock) { clock.shift || (clock << 999.0).first }
    # Test harness output is StringIO -> interactive_input? false; the burst
    # collector is deliberately gated to real consoles, so opt in explicitly.
    @shell.define_singleton_method(:paste_burst_eligible?) { true }
    Reline.stub(:readline, ->(_prompt, _add_hist) { lines.shift }) do
      @shell.run_interactive
    end
    executed
  end

  def test_paste_burst_joins_into_single_turn
    # Lines arriving 10ms apart (within the 120ms join window) join into ONE turn.
    # The leading empty Enter models the prompt keypress right before the paste:
    # it stamps last_line_at so the FIRST pasted line can also join the burst
    # (a held first line would freeze manual input on a blocking readline).
    clock = [0.0, 0.010, 0.020, 0.030, 0.040]
    lines = ["", "def foo", "  1 + 1", "end", "\x04", "exit"]
    executed = executed_shell(lines, clock)
    turns = executed.reject { |t| t.strip.empty? }
    assert_equal 1, turns.size, "paste burst must submit as one turn, got: #{executed.inspect}"
    assert_equal "def foo\n  1 + 1\nend", turns.first
  end

  def test_slow_manual_lines_do_not_join
    # 500ms apart: far beyond the 120ms join window -> each line its own turn.
    clock = [0.0, 0.5, 1.0, 1.5]
    lines = ["first prompt", "second prompt", "exit"]
    executed = executed_shell(lines, clock)
    assert_equal "first prompt", executed[0]
    assert_equal "second prompt", executed[1]
  end

  def test_explicit_paste_mode_collects_until_dot
    executed = []
    @shell.define_singleton_method(:execute_input) { |text| executed << text }
    @shell.instance_variable_set(:@paste_requested, true)
    paste_lines = ["line A", "line B", ".", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { paste_lines.shift }) do
      @shell.run_interactive
    end

    assert_includes executed, "line A\nline B", "!paste block must arrive as one joined turn"
  end

  def test_explicit_paste_mode_never_consults_timing
    # Plan 91 guarantee: `!paste` is the deterministic fallback — collection
    # must be purely delimiter-driven. Stubbing paste_clock to RAISE proves
    # the mode never consults the timing heuristic: a slow clipboard/SSH
    # stream can never split the block, no matter how long the gaps are.
    executed = []
    @shell.define_singleton_method(:execute_input) { |text| executed << text }
    @shell.define_singleton_method(:paste_clock) { raise "paste mode must not consult timing" }
    @shell.instance_variable_set(:@paste_requested, true)
    # Blank line inside the block and (simulated) arbitrarily slow delivery.
    paste_lines = ["def foo", "", "  1 + 1", ".", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { paste_lines.shift }) do
      @shell.run_interactive
    end

    assert_equal ["def foo\n\n  1 + 1"], executed,
                 "paste block must be one timing-independent turn, got: #{executed.inspect}"
  end

  def test_explicit_paste_mode_preserves_empty_and_trailing_lines
    # Block must not be trimmed or split: leading, inner, and trailing empty
    # lines inside the paste block survive verbatim into the submitted turn.
    executed = []
    @shell.define_singleton_method(:execute_input) { |text| executed << text }
    @shell.instance_variable_set(:@paste_requested, true)
    paste_lines = ["", "a = 1", "", "", "b = 2", "", ".", "exit"]
    Reline.stub(:readline, ->(_prompt, _add_hist) { paste_lines.shift }) do
      @shell.run_interactive
    end

    assert_equal "\na = 1\n\n\nb = 2\n", executed.first,
                 "empty lines inside a paste block must be preserved verbatim"
  end

  def test_paste_join_window_config
    assert_equal 120, @shell.paste_join_window_ms
  end

  def test_paste_pending_is_false_in_non_interactive_context
    # StringIO output -> interactive_input? false -> paste_pending? false
    # (Windows gate's in_pasting? may be a false positive on non-TTY stdin).
    assert_equal false, @shell.paste_pending?
  end

  def test_paste_line_fast_boundary
    @shell.define_singleton_method(:paste_clock) { 0.0 }
    assert @shell.paste_line_fast?(1.0, 1.1), "110ms gap is within a 120ms window"
    refute @shell.paste_line_fast?(1.0, 1.2), "200ms gap exceeds a 120ms window"
    refute @shell.paste_line_fast?(nil, 1.1), "nil last timestamp never counts as fast"
  end
end
