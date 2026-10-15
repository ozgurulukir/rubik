# frozen_string_literal: true

require_relative "../test_helper"
require "json"
begin
  require "pty"
rescue LoadError
  # The tests skip on platforms without PTYs.
end

class TestPromptGracePTY < Minitest::Test
  PROBE = File.expand_path("../support/prompt_grace_probe.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  def test_escape_restores_editable_unicode_multiline_without_executing
    probe do |reader, writer|
      read_until(reader, "PROMPT>")
      writer.write("<<EOF\r")
      read_until(reader, "PROMPT>")
      writer.write("  İstanbul\r")
      read_until(reader, "PROMPT>")
      writer.write("世界  \r")
      read_until(reader, "PROMPT>")
      writer.write("EOF\r")
      read_until(reader, Rubik::REPL::PromptGrace::STATUS)
      writer.write("\e")
      restored = read_until(reader, "世界")
      refute_includes restored, "EXECUTED"
      writer.write("\x05!\r") # end-of-line, append, explicitly resubmit
      output = read_until(reader, "PROBE_DONE")
      executions = output.scan(/EXECUTED (.+)\r?$/).flatten
      assert_equal 1, executions.length
      assert_equal "  İstanbul\n世界  !", JSON.parse(executions.first)
    end
  end

  def test_arrow_and_enter_do_not_cancel_or_submit_a_second_turn
    probe do |reader, writer|
      read_until(reader, "PROMPT>")
      writer.write("hello\r")
      read_until(reader, Rubik::REPL::PromptGrace::STATUS)
      writer.write("\e[A\r")
      output = read_until(reader, "PROBE_DONE")
      assert_includes output, "\a"
      assert_equal 1, output.scan('EXECUTED "hello"').length
    end
  end

  def test_ctrl_c_cancels_and_leaves_terminal_ready_for_new_input
    probe do |reader, writer|
      read_until(reader, "PROMPT>")
      writer.write("cancel me\r")
      read_until(reader, Rubik::REPL::PromptGrace::STATUS)
      writer.write("\x03")
      output = read_until(reader, "PROMPT>")
      refute_includes output, "EXECUTED"
      writer.write("replacement\r")
      assert_includes read_until(reader, "PROBE_DONE"), 'EXECUTED "replacement"'
    end
  end

  private

  def probe
    skip "PTY unavailable" if !defined?(PTY) || Gem.win_platform?
    PTY.spawn({ "TERM" => "xterm", "RUBIK_TEST" => "0" }, RbConfig.ruby, "-I", LIB, PROBE) do |reader, writer, pid|
      @pending = +""
      yield reader, writer
    ensure
      begin
        Process.kill("KILL", pid)
      rescue
        nil
      end
      begin
        Process.wait(pid)
      rescue
        nil
      end
    end
  end

  def read_until(reader, marker)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    until @pending.include?(marker)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "PTY timed out waiting for #{marker.inspect}: #{@pending.inspect}" unless remaining.positive? && reader.wait_readable(remaining)
      @pending << reader.readpartial(4096).force_encoding(Encoding::UTF_8)
    end
    # Keep data after the marker for the next synchronization point.
    boundary = @pending.index(marker) + marker.length
    @pending.slice!(0, boundary)
  rescue EOFError, Errno::EIO
    flunk "PTY ended before #{marker.inspect}: #{@pending.inspect}"
  end
end
