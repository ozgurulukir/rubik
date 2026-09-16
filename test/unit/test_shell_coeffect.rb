# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/rubik"

# Behavior lock for the 'shell' coeffect (Rubik::Coeffects::SHELL) — review
# Öneri 4 (ambient root sunset, Plan 90). The ambient root
# (Rubik.current_shell / Rubik.runtime_manager) stays in dual-publication
# during sunset; this file pins the sanctioned context access path.
class TestShellCoeffect < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_shell_coeffect")
    @home_dir = Dir.mktmpdir("rubik_shell_coeffect_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @home_dir)
    @shell = Rubik::REPL::Shell.new(config: @config, output: StringIO.new)
  end

  def teardown
    @shell&.stop
    FileUtils.rm_rf(@temp_dir)
    FileUtils.rm_rf(@home_dir)
  end

  # 1. Publication: a fully constructed shell publishes itself as the SHELL
  #    coeffect into the runtime context (wire_runtime_context via warm_up!).
  def test_shell_published_as_coeffect_on_construction
    assert_same @shell, @shell.runtime_manager.context.get(Rubik::Coeffects::SHELL)
    # Dual-publication window: ambient root still mirrors the shell.
    assert_same @shell, Rubik.current_shell
  end

  # 2. SSOT read path: Coeffects.get resolves the canonical key (no alias
  #    needed for SHELL — the key is declared directly in the SSOT).
  def test_ssot_read_path_returns_same_instance
    assert_same @shell, Rubik::Coeffects.get(@shell.runtime_manager.context, Rubik::Coeffects::SHELL)
  end

  # 3. Teardown: shell.stop identity-guards the ambient root and disposes
  #    the runtime context. The coeffect disappears with the context.
  def test_stop_clears_ambient_root_and_disposes_context
    shell = @shell
    @shell = nil # teardown must not stop twice
    shell.stop

    assert_nil Rubik.current_shell
    assert shell.runtime_manager.context.disposed?
  end

  # 4. Fresh provide on a standalone manager: String/Symbol normalization
    # and zero-restart — re-providing swaps the value without growing the
    # Omega accumulator (single delete-inverse per key).
  def test_fresh_provide_normalizes_and_keeps_omega_flat
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::Runtime::Manager.new(ctx)
    sentinel = Object.new

    manager.provide(:shell, sentinel)
    assert_same sentinel, Rubik::Coeffects.get(ctx, :shell)

    baseline = ctx.disposable_count
    manager.provide("SHELL", Object.new)
    assert_equal baseline, ctx.disposable_count, "re-provide must not stack inverses (zero-restart)"
  end
end
