# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestReplHooks < Minitest::Test
  def setup
    @logger_io = StringIO.new
    @logger = Logger.new(@logger_io)
    @hooks = Rubik::REPL::Hooks.new(logger: @logger)
  end

  def test_register_returns_unsubscribe_token_and_triggers
    calls = []
    token = @hooks.register(:before_command) { |cmd| calls << cmd }
    refute_nil token

    @hooks.trigger(:before_command, "status")
    assert_equal ["status"], calls
  end

  def test_unregister_removes_listener_symmetrically
    calls = []
    token = @hooks.register(:after_command) { |cmd| calls << cmd }

    @hooks.trigger(:after_command, "diff")
    assert_equal ["diff"], calls

    @hooks.unregister(:after_command, token)

    @hooks.trigger(:after_command, "status")
    assert_equal ["diff"], calls, "Unregistered listener must not receive further events"
  end

  def test_unregister_nil_or_unknown_token_is_safe
    @hooks.unregister(:before_command, nil)
    @hooks.unregister(:before_command, -> {})
  end

  def test_trigger_isolates_listener_errors
    calls = []
    @hooks.register(:before_command) { raise "faulty hook" }
    @hooks.register(:before_command) { |cmd| calls << cmd }

    @hooks.trigger(:before_command, "run")
    assert_equal ["run"], calls, "Later listener must execute even if earlier listener raises"
    assert_includes @logger_io.string, "Hook error on event 'before_command'"
    assert_includes @logger_io.string, "faulty hook"
  end

  def test_context_on_dispose_unregistration
    ctx = Rubik::Runtime::Context.new
    calls = []

    token = @hooks.register(:before_command) { |cmd| calls << cmd }
    ctx.on_dispose { @hooks.unregister(:before_command, token) }

    @hooks.trigger(:before_command, "one")
    assert_equal ["one"], calls

    ctx.dispose

    @hooks.trigger(:before_command, "two")
    assert_equal ["one"], calls, "Listener must be removed when context is disposed"
  end

  def test_thread_safety_during_concurrent_register_and_trigger
    threads = []
    trigger_calls = 0
    mutex = Mutex.new

    10.times do
      threads << Thread.new do
        50.times do
          token = @hooks.register(:file_changed) do
            mutex.synchronize { trigger_calls += 1 }
          end
          @hooks.trigger(:file_changed, "foo.rb")
          @hooks.unregister(:file_changed, token)
        end
      end
    end

    threads.each(&:join)
    assert trigger_calls > 0
  end
end
