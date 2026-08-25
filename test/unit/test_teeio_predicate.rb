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
    # Source check: Shell's yes/no block should call
    # @output.test_capture?, not @output.string_io?.
    src = File.read("lib/rubik/repl/shell.rb")
    assert_match(/@output\.test_capture\?/, src,
                 "shell.rb should use @output.test_capture?")
  end

  def test_agent_uses_test_capture_predicate
    src = File.read("lib/rubik/repl/commands/agent.rb")
    assert_match(/shell\.output\.test_capture\?/, src,
                 "agent.rb should use shell.output.test_capture?")
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
