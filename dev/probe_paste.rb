# frozen_string_literal: true

# Plan 91 diagnostic probe: boots the REPL Shell against a StringIO output
# with stubbed Reline.readline, mirroring test_paste_support setup, and
# prints progress markers so a hang localizes to a specific phase.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "stringio"
require "rubik"

puts "[probe] rubik loaded"
shell = Rubik::REPL::Shell.new(output: StringIO.new)
puts "[probe] shell constructed: #{shell.class}"

lines = ["", "def foo", "  1 + 1", "end", "\x04", "exit"]
clock = [0.0, 0.010, 0.020, 0.030, 0.040]
executed = []
shell.define_singleton_method(:execute_input) { |text| executed << text }
shell.define_singleton_method(:paste_clock) { clock.shift || (clock << 999.0).first }
shell.define_singleton_method(:paste_burst_eligible?) { true }
puts "[probe] singletons installed, eligible=#{shell.paste_burst_eligible?}"

Reline.singleton_class.send(:alias_method, :orig_readline_probe, :readline)
Reline.define_singleton_method(:readline) { |*_args| lines.shift }
puts "[probe] readline stubbed with #{lines.size} lines"

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
shell.run_interactive
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "[probe] run_interactive returned in #{(dt * 1000).round(1)}ms"
puts "[probe] executed = #{executed.inspect}"

Reline.singleton_class.send(:remove_method, :readline)
puts "[probe] done"
