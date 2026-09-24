# frozen_string_literal: true

require_relative "../test_helper"

class TestTeeioIsolation < Minitest::Test
  def setup
    @orig_stderr = $stderr
  end

  def teardown
    $stderr = @orig_stderr
  end

  def capture_stderr
    captured = StringIO.new
    $stderr = captured
    yield
    captured.string
  end

  # A user-stream stand-in whose every write path raises.
  def failing_target
    target = Object.new
    %i[puts print write printf].each do |m|
      target.define_singleton_method(m) { |*| raise IOError, "stream closed" }
    end
    target.define_singleton_method(:flush) { raise IOError, "stream closed" }
    target
  end

  def test_recorder_survives_a_failing_user_stream
    recorder = StringIO.new
    tee = Rubik::REPL::TeeIO.new(failing_target, recorder)

    err_out = capture_stderr { tee.puts "line one" }

    assert_equal "line one\n", recorder.string, "recorder (LAST) must receive writes when the user stream raises"
    assert_includes err_out, "tee target failed"
    assert_includes err_out, "IOError"
  end

  def test_failing_target_is_detached_after_first_warning
    recorder = StringIO.new
    tee = Rubik::REPL::TeeIO.new(failing_target, recorder)

    err_out = capture_stderr do
      tee.puts "one"
      tee.puts "two"
    end

    assert_equal "one\ntwo\n", recorder.string
    assert_equal 1, err_out.scan("tee target failed").size, "warn once, then detach — no repeat warnings"
    assert_equal [recorder], tee.targets, "failed target pruned from the tee"
  end

  def test_flush_survives_failing_target_and_flushes_rest
    recorder = StringIO.new
    real = StringIO.new
    tee = Rubik::REPL::TeeIO.new(failing_target, real, recorder)

    result = nil
    capture_stderr do
      tee.write "x"
      result = tee.flush
    end

    assert_nil result, "flush keeps its never-raise contract"
    assert_equal "x", real.string
    assert_equal "x", recorder.string
  end

  def test_middle_target_failure_does_not_starve_neighbors
    recorder = StringIO.new
    first = StringIO.new
    tee = Rubik::REPL::TeeIO.new(first, failing_target, recorder)

    capture_stderr { tee.write "payload" }

    assert_equal "payload", first.string, "targets BEFORE the failure still receive the write"
    assert_equal "payload", recorder.string, "targets AFTER the failure still receive the write"
  end
end
