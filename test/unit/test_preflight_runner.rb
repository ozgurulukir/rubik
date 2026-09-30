# frozen_string_literal: true

require_relative "../test_helper"

class TestPreflightRunner < Minitest::Test
  # A real Guard: the spawn boundary must actually verify, and every benign
  # snippet below must keep passing it.
  def guard
    @guard ||= Rubik::Security::Guard.new
  end

  # ── subprocess success paths ───────────────────────────────────────

  def test_success_returns_nil_and_computes_result
    res = Rubik::Tools::PreflightRunner.run('->(args) { args["n"] * 2 }', { "n" => 21 }, mode: :tool, guard: guard)
    assert_nil res
  end

  def test_command_mode_dispatches_arity_with_stringio_and_nil_shell
    # NOTE: single-quoted on purpose — the handler code must reach the child
    # verbatim; a double-quoted/%{} literal would interpolate #{args} here.
    # Arity-3 handlers receive a StringIO and nil shell in pre-flight.
    res = Rubik::Tools::PreflightRunner.run('->(args, out, shell) { raise "shell leaked" if shell; out.puts "hi" }', { "x" => 1 },
                                            mode: :command, guard: guard)
    assert_nil res
  end

  def test_tool_mode_calls_handler_with_exactly_one_argument
    # Mirrors the ToolWrapper contract: an arity-2 handler must FAIL under
    # mode: :tool, because the wrapper only ever passes args.
    res = Rubik::Tools::PreflightRunner.run("->(args, out) { true }", {}, mode: :tool, guard: guard)
    assert_kind_of String, res
    assert_includes res, "ArgumentError"
  end

  # ── spawn-boundary guard (defense-in-depth) ────────────────────────

  def test_run_requires_guard_kwarg
    error = assert_raises(ArgumentError) do
      Rubik::Tools::PreflightRunner.run("->(args) { 1 }", {}, mode: :tool)
    end
    assert_includes error.message, "guard"
  end

  def test_run_with_guard_blocks_dangerous_code_before_spawn
    res = Rubik::Tools::PreflightRunner.run("->(args) { system('rm -rf /') }", {}, mode: :tool, guard: guard)

    # A security verdict must surface as the error-String contract, never
    # :spawn_failed — the caller's in-process fallback would run the
    # blocked code.
    assert_kind_of String, res
    assert_includes res, "security verification failed"
  end

  # ── failure paths ──────────────────────────────────────────────────

  def test_runtime_error_is_surfaced
    res = Rubik::Tools::PreflightRunner.run('->(args) { raise "boom" }', {}, mode: :tool, guard: guard)
    assert_kind_of String, res
    assert_includes res, "RuntimeError: boom"
  end

  def test_syntax_error_is_surfaced
    res = Rubik::Tools::PreflightRunner.run("->( { broken", {}, mode: :tool, guard: guard)
    assert_kind_of String, res
    assert_includes res, "SyntaxError"
  end

  def test_non_callable_code_is_surfaced
    res = Rubik::Tools::PreflightRunner.run("42", {}, mode: :tool, guard: guard)
    assert_kind_of String, res
    assert_includes res, "callable"
  end

  # ── hard kill deadline (the reason this runner exists) ─────────────

  def test_runaway_handler_is_killed_at_deadline
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = Rubik::Tools::PreflightRunner.run("->(args) { sleep 30 }", {}, mode: :tool, timeout: 1, guard: guard)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_kind_of String, res
    assert_includes res, "execution timed out after 1 seconds"
    # The child is hard-killed: the runner must return near the deadline,
    # not after the handler's full 30s sleep.
    assert_operator elapsed, :<, 10, "subprocess must be killed at the deadline"
  end

  # ── in-process fallback ────────────────────────────────────────────

  def test_verify_in_process_success_and_failure
    assert_nil(Rubik::Tools::PreflightRunner.verify_in_process { true })
    err = Rubik::Tools::PreflightRunner.verify_in_process { raise "inline boom" }
    assert_includes err, "RuntimeError: inline boom"
  end

  def test_verify_in_process_timeout
    err = Rubik::Tools::PreflightRunner.verify_in_process(timeout: 1) { sleep 10 }
    assert_includes err, "execution timed out after 1 seconds"
  end

  def test_call_handler_mirrors_child_dispatch
    out = Rubik::Tools::PreflightRunner.call_handler(lambda { |_args, out2, _shell|
      out2.print "x"
      out2
    }, { "a" => 1 }, mode: :command)
    assert_equal "x", out.string
    # mode: :tool passes exactly one argument
    assert_equal 3, Rubik::Tools::PreflightRunner.call_handler(->(args) { args }, 3, mode: :tool)
  end
end
