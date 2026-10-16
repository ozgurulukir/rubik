# frozen_string_literal: true

require_relative "../test_helper"

begin
  require "pty"
rescue LoadError
  # Windows: pty is unavailable; the test skips below.
end

# Reactive-wakeup install contract (reline field report 2026-10-13): the idle
# prompt kick (Lifecycle#request_reactive_wakeup! -> TerminalGuard#safe_wakeup!
# -> Reline.ungetc) only reaches a reader ALREADY blocked inside Reline's getc
# loop on reline >= 0.7.0, whose ANSI gate re-checks the ungetc buffer on every
# ~10ms poll iteration. Reline 0.6.x checks that buffer once at getc entry and
# then waits on raw terminal input, so the injected Enter strands until the
# next keystroke — the "maestro only wakes when I press a key" report.
# rubik.gemspec floors reline >= 0.7 for exactly this; this test pins the
# contract against the gate the environment actually loads (probe child under
# a PTY — unit doubles cannot see gate internals).
class TestRelineWakeupContract < Minitest::Test
  REPO_LIB = File.expand_path("../../lib", __dir__)
  PROBE_SCRIPT = File.expand_path("../support/reline_wake_probe.rb", __dir__)
  PROBE_DEADLINE_SECONDS = 30.0

  def test_ungetc_wakeup_reaches_a_blocked_readline_without_keystrokes
    skip "PTY is not available on this platform (Windows)" if !defined?(PTY) || Gem.win_platform?

    output = run_probe

    assert_includes output, "WAKE_READY true", "probe never parked the reader inside Reline's getc loop"
    assert_includes output, "WAKE_KICK true", "safe_wakeup! refused the kick (guard preconditions)"
    assert_includes output, "WAKE_RETURNED true",
                    "Reline #{probe_reline_version(output)} stranded the injected Enter: the blocked readline " \
                    "did not return without a keystroke. This is the maestro reactive-wakeup regression — keep " \
                    "the gemspec reline >= 0.7 floor, or make safe_wakeup! version-independent first."
  end

  private

  def run_probe
    output = +""
    PTY.spawn({ "TERM" => "xterm" }, RbConfig.ruby, "-I", REPO_LIB, PROBE_SCRIPT) do |reader, _writer, pid|
      collect_probe_output(reader, output)
      terminate(pid)
    end
    output
  end

  def collect_probe_output(reader, output)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROBE_DEADLINE_SECONDS
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0
      break unless reader.wait_readable(remaining)

      begin
        output << reader.readpartial(4096)
      rescue EOFError, Errno::EIO
        break
      end
      break if output.include?("WAKE_RETURNED") || output.include?("WAKE_READY false")
    end
  end

  def terminate(pid)
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  ensure
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def probe_reline_version(output)
    output[/WAKE_VERSION (\S+)/, 1] || "unknown"
  end
end
