# frozen_string_literal: true

require_relative "../test_helper"

# G6 structured logging core: level filtering, env override, single-line
# format, and emit error-isolation.
class TestLog < Minitest::Test
  def with_log_level(level)
    old = ENV.fetch("RUBIK_LOG_LEVEL", nil)
    ENV["RUBIK_LOG_LEVEL"] = level
    yield
  ensure
    if old.nil?
      ENV.delete("RUBIK_LOG_LEVEL")
    else
      ENV["RUBIK_LOG_LEVEL"] = old
    end
  end

  def test_warn_and_error_emit_by_default
    out, err = capture_io do
      Rubik::Log.warn(:runtime, "beware")
      Rubik::Log.error(:runtime, "broken")
      Rubik::Log.info(:runtime, "quiet")
      Rubik::Log.debug(:runtime, "quieter")
    end

    assert_empty out
    assert_includes err, "[rubik] warn runtime: beware"
    assert_includes err, "[rubik] error runtime: broken"
    refute_includes err, "quiet"
  end

  def test_log_level_env_opens_info_and_debug
    with_log_level("info") do
      _out, err = capture_io do
        Rubik::Log.info(:test, "visible now")
        Rubik::Log.debug(:test, "still hidden")
      end
      assert_includes err, "[rubik] info test: visible now"
      refute_includes err, "still hidden"
    end
  end

  def test_invalid_log_level_falls_back_to_warn
    with_log_level("shout") do
      _out, err = capture_io do
        Rubik::Log.warn(:test, "still warned")
        Rubik::Log.info(:test, "filtered")
      end
      assert_includes err, "still warned"
      refute_includes err, "filtered"
    end
  end

  def test_emit_never_raises
    broken_stderr = ->(_line) { raise IOError, "io dead" }
    assert_silent do
      # stub inside the capture: assert_silent swaps $stderr to a StringIO,
      # and the stub must patch THAT object to intercept the write
      $stderr.stub(:puts, broken_stderr) { Rubik::Log.warn(:test, "ok") }
    end
  end
end
