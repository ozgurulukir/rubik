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

  def test_interrupt_completes_drain_then_reraises
    ctx = Rubik::Runtime::Context.new
    order = []
    ctx.on_dispose { order << :first }
    ctx.on_dispose { raise Interrupt, "Ctrl+C mid-drain" }
    ctx.on_dispose { order << :last }

    err_out = capture_stderr do
      assert_raises(Interrupt) { ctx.dispose }
    end

    assert_equal [:last, :first], order, "LIFO drain must complete past the interrupted inverse"
    assert_equal 1, ctx.last_dispose_errors.size
    assert_instance_of Interrupt, ctx.last_dispose_errors.first
    assert_includes err_out, "deferred until drain completes"
    assert ctx.disposed?
    assert_equal 0, ctx.disposable_count
  end

  def test_systemexit_and_interrupt_defer_first_encountered_wins
    ctx = Rubik::Runtime::Context.new
    order = []
    ctx.on_dispose { order << :first }
    ctx.on_dispose { raise SystemExit }
    ctx.on_dispose { raise Interrupt }
    ctx.on_dispose { order << :last }

    capture_stderr do
      # LIFO pops :last → Interrupt (FIRST deferred) → SystemExit → :first;
      # the first signal encountered during the drain is the one re-raised.
      assert_raises(Interrupt) { ctx.dispose }
    end

    assert_equal [:last, :first], order
    assert_equal 2, ctx.last_dispose_errors.size
    assert ctx.disposed?
    assert_equal 0, ctx.disposable_count
  end

  def test_child_interrupt_does_not_abort_parent_drain_and_still_prunes
    parent = Rubik::Runtime::Context.new
    parent_order = []
    parent.on_dispose { parent_order << :parent_first }
    parent.on_dispose { parent_order << :parent_last }
    child = parent.extend
    child.on_dispose { raise Interrupt, "child interrupted" }

    capture_stderr do
      assert_raises(Interrupt) { parent.dispose }
    end

    assert_equal %i[parent_last parent_first], parent_order, "parent's own inverses must still drain"
    assert parent.disposed?
    assert child.disposed?
    assert_equal 0, parent.disposable_count, "cascade inverse + child bookkeeping pruned"
  end

  def test_child_own_dispose_reraises_interrupt_and_prunes_parent
    parent = Rubik::Runtime::Context.new
    child = parent.extend
    child.on_dispose { raise Interrupt }

    capture_stderr { assert_raises(Interrupt) { child.dispose } }

    assert child.disposed?
    assert_equal 0, parent.disposable_count, "prune_child must run despite the deferred signal"
  end

  def test_late_inverse_interrupt_propagates_immediately
    ctx = Rubik::Runtime::Context.new
    ctx.dispose

    # Sealed immediate-run path: no accumulator remains to drain, so the
    # signal needs no deferral — it surfaces synchronously.
    assert_raises(Interrupt) { ctx.on_dispose { raise Interrupt } }
  end

  def test_manager_dispose_unwinds_fibers_lifo
    manager = Rubik::Runtime::Manager.new
    order = []

    f1 = Rubik::Runtime::ComponentFiber.new(name: "f1") { |ctx| ctx.on_dispose { order << :f1 } }
    f2 = Rubik::Runtime::ComponentFiber.new(name: "f2") { |ctx| ctx.on_dispose { order << :f2 } }
    f3 = Rubik::Runtime::ComponentFiber.new(name: "f3") { |ctx| ctx.on_dispose { order << :f3 } }

    manager.register_fiber(f1)
    manager.register_fiber(f2)
    manager.register_fiber(f3)

    manager.dispose!

    assert_equal %i[f3 f2 f1], order, "Fibers must unwind in strict reverse order (LIFO)"
    assert manager.disposed?
    assert manager.context.disposed?
  end

  def test_manager_dispose_isolates_fiber_failure_and_ensures_context_dispose
    manager = Rubik::Runtime::Manager.new
    order = []

    f1 = Rubik::Runtime::ComponentFiber.new(name: "f1") { |ctx| ctx.on_dispose { order << :f1 } }
    f_broken = Rubik::Runtime::ComponentFiber.new(name: "broken") { |_ctx| }
    def f_broken.dispose!; raise "fiber error"; end
    f3 = Rubik::Runtime::ComponentFiber.new(name: "f3") { |ctx| ctx.on_dispose { order << :f3 } }

    manager.register_fiber(f1)
    manager.register_fiber(f_broken)
    manager.register_fiber(f3)

    err = capture_stderr { manager.dispose! }

    assert_equal %i[f3 f1], order, "Unwind must complete remaining fibers despite one failing"
    assert_includes err, "fiber 'broken' dispose failed"
    assert manager.disposed?
    assert manager.context.disposed?, "context.dispose must run in ensure"
  end

  def test_manager_dispose_is_idempotent
    manager = Rubik::Runtime::Manager.new
    calls = []
    f = Rubik::Runtime::ComponentFiber.new(name: "f") { |ctx| ctx.on_dispose { calls << :disposed } }
    manager.register_fiber(f)

    manager.dispose!
    manager.dispose!

    assert_equal 1, calls.size, "Second dispose! must be a no-op"
  end

  def test_manager_rejects_register_after_dispose
    manager = Rubik::Runtime::Manager.new
    manager.dispose!

    f = Rubik::Runtime::ComponentFiber.new(name: "late") { |_ctx| }
    assert_raises(Rubik::Runtime::ContextDisposedError) do
      manager.register_fiber(f)
    end
    assert_raises(Rubik::Runtime::ContextDisposedError) do
      manager.register_component("late_comp") { |_ctx| }
    end
  end
end
