# frozen_string_literal: true

require_relative "../test_helper"

# Pins the fail-closed guard fallback on TaskManager (#405): a bare
# construction must never leave the Open3.popen3 sink unguarded, and an
# explicitly injected guard must be honored verbatim.
class TestTaskManagerGuardFallback < Minitest::Test
  def teardown
    @manager&.kill_all
  end

  # A fresh fallback Guard blocks a dangerous command before spawn and no
  # task is ever registered.
  def test_missing_guard_falls_back_to_fresh_guard_and_blocks_dangerous_command
    @manager = Rubik::Runtime::TaskManager.new
    assert_kind_of Rubik::Security::Guard, @manager.guard

    assert_raises(Rubik::Security::BlockedWriteError) do
      @manager.start("rm -rf /")
    end
    assert_empty @manager.list
  end

  # The fresh fallback is fail-closed, not dangerous-pattern-only: an
  # unclassifiable binary must not sneak through the unguarded construction.
  def test_missing_guard_fallback_blocks_unclassifiable_command
    @manager = Rubik::Runtime::TaskManager.new

    assert_raises(Rubik::Security::BlockedWriteError) do
      @manager.start("definitely_not_a_real_binary_xyz_123 --version")
    end
    assert_empty @manager.list
  end

  # An explicitly passed guard is the one consulted at the sink — the
  # fallback must not shadow the session guard that carries operator policy.
  def test_explicit_guard_is_consulted_and_honored
    verified = []
    guard = Object.new
    guard.define_singleton_method(:verify_command_safety!) do |cmd|
      verified << cmd
      raise Rubik::Security::BlockedWriteError, "blocked by test stub"
    end
    @manager = Rubik::Runtime::TaskManager.new(guard: guard)
    assert_same guard, @manager.guard

    assert_raises(Rubik::Security::BlockedWriteError) do
      @manager.start("rm -rf /")
    end
    assert_equal ["rm -rf /"], verified
    assert_empty @manager.list
  end
end
