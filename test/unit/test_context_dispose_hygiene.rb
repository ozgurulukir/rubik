# frozen_string_literal: true

require_relative "../test_helper"

class TestContextDisposeHygiene < Minitest::Test
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

  def test_failing_inverse_does_not_abort_lifo_unwind
    ctx = Rubik::Runtime::Context.new
    order = []
    ctx.on_dispose { order << :first }
    ctx.on_dispose { raise "boom" }
    ctx.on_dispose { order << :last }

    err_out = capture_stderr { ctx.dispose }

    assert_equal [:last, :first], order, "LIFO unwind must complete past the failing inverse"
    assert_equal 1, ctx.last_dispose_errors.size
    assert_equal "boom", ctx.last_dispose_errors.first.message
    assert_includes err_out, "dispose inverse failed"
    assert_includes err_out, "boom"
    assert ctx.disposed?
    assert_equal 0, ctx.disposable_count
  end

  def test_clean_dispose_records_no_errors
    ctx = Rubik::Runtime::Context.new
    ctx.provide("svc", Object.new)
    err_out = capture_stderr { ctx.dispose }

    assert_equal "", err_out
    assert_empty ctx.last_dispose_errors
  end

  def test_child_dispose_errors_do_not_leak_to_parent
    parent = Rubik::Runtime::Context.new
    child = parent.extend
    child.on_dispose { raise "child boom" }

    err_out = capture_stderr { parent.dispose }

    assert_includes err_out, "child boom"
    assert_equal 0, parent.last_dispose_errors.size, "child failures must not surface on the parent accumulator"
    assert_equal 1, child.last_dispose_errors.size
    assert parent.disposed?
    assert child.disposed?
  end

  def test_dispose_is_idempotent_after_failure
    ctx = Rubik::Runtime::Context.new
    calls = []
    ctx.on_dispose { raise "first boom" }
    ctx.on_dispose { calls << :ran }

    capture_stderr { ctx.dispose }
    errors_after_first = ctx.last_dispose_errors.size
    capture_stderr { ctx.dispose }

    assert_equal 1, calls.size, "second dispose must be a no-op"
    assert_equal errors_after_first, ctx.last_dispose_errors.size
  end
end
