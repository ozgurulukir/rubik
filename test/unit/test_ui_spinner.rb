# frozen_string_literal: true

require_relative "../test_helper"
require_relative "test_ui_capability"

class TestUISpinner < Minitest::Test
  def setup
    @tmp_dirs = []
  end

  def teardown
    @tmp_dirs.each { |d| FileUtils.rm_rf(d) }
  end

  def fresh_config
    root = Dir.mktmpdir("rubik_spin")
    home = Dir.mktmpdir("rubik_spin_home")
    @tmp_dirs << root << home
    Rubik::Config.new(root_dir: root, home_dir: home)
  end

  def theme
    Rubik::UI::Theme.new(enabled: true)
  end

  def test_start_and_stop_lifecycle_on_tty
    io = FakeTTYIO.new
    spinner = Rubik::UI::Spinner.new(io, theme)

    spinner.start(step: 1, max_steps: 40)
    assert spinner.spinning?

    spinner.stop
    refute spinner.spinning?
  end

  def test_stop_is_idempotent
    spinner = Rubik::UI::Spinner.new(FakeTTYIO.new, theme)
    spinner.stop
    spinner.stop
    refute spinner.spinning?
  end

  def test_repeated_cycles_do_not_leak_threads
    baseline = Thread.list.size
    spinner = Rubik::UI::Spinner.new(FakeTTYIO.new, theme)

    50.times do
      spinner.start(step: 1, max_steps: 10)
      spinner.stop
    end

    assert_operator Thread.list.size, :<=, baseline + 1,
                    "spinner threads must not accumulate (AGENTS.md leaked-side-effect rule)"
  ensure
    spinner&.kill
  end

  def test_kill_alias_matches_stop
    spinner = Rubik::UI::Spinner.new(FakeTTYIO.new, theme)
    spinner.start
    spinner.kill
    refute spinner.spinning?
  end

  def test_disabled_via_config_never_spins
    config = fresh_config
    config.set("ui.spinner", false)
    spinner = Rubik::UI::Spinner.new(FakeTTYIO.new, theme, config: config)

    refute spinner.enabled?
    spinner.start
    refute spinner.spinning?
  end

  def test_context_dispose_kills_live_spinner_via_lifo_inverse
    # The AGENTS.md guarantee, actually exercised: a live spinner thread is
    # terminated by the context's registered inverse, not by happenstance.
    ctx = Rubik::Runtime::Context.new
    spinner = Rubik::UI::Spinner.new(FakeTTYIO.new, theme)
    ctx.on_dispose { spinner.kill }

    spinner.start(step: 1, max_steps: 5)
    assert spinner.spinning?
    ctx.dispose
    refute spinner.spinning?
  end

  def test_tick_failure_is_reported_not_silently_swallowed
    # AGENTS.md §5 (Silent Failure Swallowing): a tick-thread IO failure must
    # be reported to stderr and end the thread — never vanish silently.
    broken_later = Class.new do
      def initialize
        @broken = false
      end

      attr_accessor :broken

      def tty?
        true
      end

      def print(*)
        raise IOError, "simulated stream failure" if @broken

        nil
      end

      def flush; end
    end

    io = broken_later.new
    spinner = Rubik::UI::Spinner.new(io, theme)

    captured_stderr = StringIO.new
    original_stderr = $stderr
    $stderr = captured_stderr
    begin
      spinner.start(step: 1, max_steps: 5)
      assert spinner.spinning?

      io.broken = true # next tick's spin raises inside the tick thread
      sleep 0.5 # TICK_SECONDS = 0.12 → several ticks elapse

      refute spinner.spinning?, "tick thread must exit after its failure"
      assert_includes captured_stderr.string, "[rubik] spinner tick failed:",
                      "tick failure must be reported to stderr, never silently swallowed"
    ensure
      $stderr = original_stderr
      begin
        spinner.stop
      rescue StandardError
        # io is broken by design; best-effort cleanup only
      end
    end
  end

  def test_render_service_refresh_keeps_omega_accumulator_bounded
    # Zero-restart rule: N refreshes must not stack N delete/kill inverses
    # into the Omega accumulator (each provide keeps exactly one inverse).
    shell = Rubik::REPL::Shell.new(config: fresh_config, output: StringIO.new)
    baseline = shell.runtime_manager.context.disposable_count

    50.times { shell.refresh_ui! }

    assert_equal baseline, shell.runtime_manager.context.disposable_count,
                 "refresh_ui! must swap services without growing Omega"
  ensure
    shell&.stop
  end
end
