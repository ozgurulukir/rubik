# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# NoticeRouter regressions (#686): the active-loop handoff must re-check
# under the standby mutex so a notice cannot strand in a dead loop's inbox,
# and MCP boot text must be sanitised before it reaches the terminal.
class TestNoticeRouterFixes < Minitest::Test
  class LoopDouble
    attr_reader :notices

    def initialize
      @notices = []
    end

    def enqueue_subagent_notice(notice)
      @notices << notice
    end
  end

  def host_double
    host = Object.new
    host.instance_variable_set(:@running, true)
    host.instance_variable_set(:@output, StringIO.new)
    host.instance_variable_set(:@conversation_history, [])
    host.instance_variable_set(:@active_loop, nil)
    host
  end

  def test_enqueue_rechecks_active_loop_under_the_mutex
    # #686: teardown clears @active_loop before draining under the same
    # mutex. A notice that read the stale loop must fall through to the idle
    # path rather than land in an inbox nobody drains again.
    host = host_double
    loop_double = LoopDouble.new
    host.instance_variable_set(:@active_loop, loop_double)
    router = Rubik::REPL::NoticeRouter.new(host)
    reads = 0
    router.define_singleton_method(:shell_state) do |name|
      next super(name) unless name == :active_loop

      reads += 1
      reads == 1 ? loop_double : nil
    end
    notice = { kind: :completed, id: "s1", role: "R", state: "completed" }

    refute router.enqueue_to_active_loop(notice, "line")
    assert_empty loop_double.notices
    assert_empty router.subagent_notices
  end

  def test_enqueue_succeeds_when_loop_is_still_active
    host = host_double
    loop_double = LoopDouble.new
    host.instance_variable_set(:@active_loop, loop_double)
    router = Rubik::REPL::NoticeRouter.new(host)
    notice = { kind: :message, id: "s2", role: "R", state: "message" }

    assert router.enqueue_to_active_loop(notice, "line")
    assert_equal [notice], loop_double.notices
    assert_equal ["line"], router.subagent_notices
  end

  def test_mcp_boot_failure_is_sanitised_and_redacted
    # #686: server name and error are process/network controlled — binary
    # bytes and embedded credentials must never reach the terminal raw.
    host = host_double
    lines = []
    guard = Object.new
    guard.define_singleton_method(:print_safe_notice) { |line| lines << line }
    host.instance_variable_set(:@terminal_guard, guard)
    router = Rubik::REPL::NoticeRouter.new(host)

    payload = { server: "srv\xFF".b, error: "api_key=supersecret \xFF".b }
    router.print_mcp_boot_notice(:failed, payload)

    assert_equal 1, lines.size
    line = lines.first
    assert line.valid_encoding?, "binary payload bytes must be scrubbed"
    refute_includes line, "supersecret", "credentials must be masked"
    assert_includes line, "mcp: server 'srv' failed"
  end
end
