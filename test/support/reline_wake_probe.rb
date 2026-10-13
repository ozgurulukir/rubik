# frozen_string_literal: true

# PTY child for test/integration/test_reline_wakeup_contract.rb. Run as
#
#   ruby -I<repo>/lib test/support/reline_wakeup_probe.rb
#
# It emits machine-readable WAKE_* lines: parks a reader inside Reline's
# blocking getc loop, fires the reactive wake once (exactly what
# TerminalGuard#safe_wakeup! does when a background notice lands on an idle
# prompt) and reports whether the blocked readline returned WITHOUT any
# keystroke — the contract the real ANSI gate owes on Reline >= 0.7.0.
# On 0.6.x the injected Enter lands in the gate's ungetc buffer but the wait
# loop never re-checks it, so the reader stays blocked: the probe reports
# WAKE_RETURNED false and the parent test fails with the actionable message.
#
# The PTY master never answers Reline's cursor-position queries (no terminal
# emulator on the master side), so the reader deterministically parks in the
# blocking loop right after the ~1s startup prelude. Readiness is detected by
# sampling the reader's backtrace — version-agnostic, no gate internals.
$stdout.sync = true

require "reline"
require "rubik/repl/terminal_guard"

READY_TIMEOUT_SECONDS = 15.0
RETURN_TIMEOUT_SECONDS = 3.0

# Blocked INSIDE the gate's getc loop: inner_getc on the stack AND the thread
# parked in the wait loop (wait_readable) or its 10ms signal pump
# (handle_signal). The second condition rules out the getc entry window where
# 0.6.x would still consume an already-queued byte.
def blocked_in_gate?(thread)
  backtrace = thread.backtrace
  return false unless backtrace

  backtrace.any? { |frame| frame.include?("inner_getc") } &&
    backtrace.any? { |frame| frame.include?("wait_readable") || frame.include?("handle_signal") }
end

puts "WAKE_VERSION #{Reline::VERSION}"

guard = Rubik::REPL::TerminalGuard.new(output: $stdout, reline: Reline)

line = :not_returned
reader = Thread.new do
  line = guard.with_reading { Reline.readline("> ", false) }
end

ready_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
sleep 0.02 until blocked_in_gate?(reader) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > ready_deadline

unless blocked_in_gate?(reader)
  puts "WAKE_READY false"
  exit 2
end

puts "WAKE_READY true"
puts "WAKE_KICK #{guard.safe_wakeup! ? true : false}"

returned = !reader.join(RETURN_TIMEOUT_SECONDS).nil?
puts "WAKE_RETURNED #{returned ? true : false}"
puts "WAKE_LINE #{line.inspect}" if returned
exit 0
