# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Tests for PR-K: TeeIO exposes a public test_capture? predicate
# instead of forcing callers to peek at string_io? implementation
# detail.
class TestTeeIOPredicate < Minitest::Test
  def test_test_capture_true_when_string_io_target
    tee = Rubik::REPL::TeeIO.new(StringIO.new)
    assert tee.test_capture?
  end

  def test_test_capture_false_for_real_io
    # Use a closed pipe to get a real IO that isn't StringIO
    r, w = IO.pipe
    begin
      tee = Rubik::REPL::TeeIO.new(w)
      refute tee.test_capture?
    ensure
      w.close
      r.close
    end
  end

  def test_test_capture_true_when_no_targets
    tee = Rubik::REPL::TeeIO.new
    assert tee.test_capture?
  end

  def test_test_capture_true_for_mixed_targets_with_stringio
    r, w = IO.pipe
    begin
      tee = Rubik::REPL::TeeIO.new(w, StringIO.new)
      assert tee.test_capture?
    ensure
      w.close
      r.close
    end
  end

  def test_string_io_still_works_for_backward_compat
    # The internal #string_io? must keep working since other code
    # (and external callers) may rely on it.
    tee = Rubik::REPL::TeeIO.new(StringIO.new)
    assert tee.string_io?
  end

  def test_shell_uses_test_capture_predicate
    # Source check: the interactivity guard (Confirmations, mixed into
    # Shell) should consult the test_capture? predicate (after unwrapping
    # TeeIO targets), never the string_io? implementation detail.
    src = File.read("lib/rubik/repl/confirmations.rb")
    assert_match(/test_capture\?/, src,
                 "confirmations.rb should use the test_capture? predicate")
    refute_match(/string_io\?/, src,
                 "confirmations.rb must not use string_io? directly")
  end

  def test_agent_delegates_interactivity_to_shell
    # The inline test_capture? sniffing moved into Shell#interactive_input?;
    # agent.rb should simply route confirmations through shell.ask_yes_no.
    src = File.read("lib/rubik/repl/commands/agent.rb")
    refute_match(/test_capture\?/, src,
                 "agent.rb must not inline test_capture? checks; delegate to shell.ask_yes_no")
    assert_match(/shell\.ask_yes_no/, src,
                 "agent.rb should use shell.ask_yes_no for confirmations")
  end

  def test_shell_no_longer_calls_string_io_directly
    # After PR-K, the only remaining string_io? call should be
    # inside tee_io.rb itself (and this test file's backward-compat
    # test).
    lib_files = Dir.glob("lib/**/*.rb")
    offenders = lib_files.reject { |f| f == "lib/rubik/repl/tee_io.rb" }
                         .select { |f| File.read(f).include?("string_io?") }
    assert_empty offenders,
                 "Files still using string_io?: #{offenders.inspect}"
  end
end
