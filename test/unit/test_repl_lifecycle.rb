# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Pins REPL::Lifecycle's private debug diagnostics channel: gated by
# ENV["RUBIK_DEBUG"], never raises, and — the regression this file exists
# for — still audible when $VERBOSE is nil (bundler/rake -W0 silences
# Kernel#warn, which the channel originally used).
class TestREPLLifecycleDiagnostics < Minitest::Test
  def host
    Object.new.extend(Rubik::REPL::Lifecycle)
  end

  def restore_env(old_debug)
    old_debug ? (ENV["RUBIK_DEBUG"] = old_debug) : ENV.delete("RUBIK_DEBUG")
  end

  def test_debug_warn_emits_when_verbose_is_nil
    old_verbose = $VERBOSE
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    old_stderr = $stderr
    captured = nil
    $VERBOSE = nil
    ENV["RUBIK_DEBUG"] = "1"
    $stderr = StringIO.new
    begin
      host.send(:debug_warn, "lifecycle warning")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
      $VERBOSE = old_verbose
    end

    assert_includes captured, "[WARN] lifecycle warning"
  end

  def test_debug_warn_silent_without_rubik_debug
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    ENV.delete("RUBIK_DEBUG")
    old_stderr = $stderr
    captured = nil
    begin
      $stderr = StringIO.new
      host.send(:debug_warn, "must not appear")
      captured = $stderr.string
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
    end

    assert_empty captured
  end

  def test_debug_warn_never_raises
    old_debug = ENV.fetch("RUBIK_DEBUG", nil)
    ENV["RUBIK_DEBUG"] = "1"
    old_stderr = $stderr
    broken = Object.new
    def broken.write(*) = 1
    def broken.puts(*) = raise "broken emit target"
    begin
      $stderr = broken
      host.send(:debug_warn, "should be swallowed")
    rescue StandardError => e
      flunk("debug_warn raised: #{e.class}: #{e.message}")
    ensure
      $stderr = old_stderr
      restore_env(old_debug)
    end
  end
end
