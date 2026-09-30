# frozen_string_literal: true

require_relative "../test_helper"

# G13: Platform::Sanitize fallback paths. These sanitizers are the last line
# between hostile bytes and the model/UI pipeline; each test pins a fallback
# arm that coverage showed as never exercised: xml_escape rescue, the
# clean_utf8 encode-failure fallback, the safe_json_* double-failure "{}"
# fallbacks and the sanitize_for_json_fallback rescue.
class TestSanitizeFallbackPaths < Minitest::Test
  # An object whose to_s raises — hostile duck type reaching a sanitizer.
  class ToSBoom
    def to_s = raise "to_s exploded"
  end

  def test_xml_escape_survives_to_s_failure
    assert_equal "", Rubik::Platform.xml_escape(ToSBoom.new)
  end

  def test_xml_escape_normal_values
    assert_equal "a &lt;b&gt;", Rubik::Platform.xml_escape("a <b>")
  end

  def test_clean_utf8_encode_failure_falls_back_to_scrub
    # UTF-7 is a dummy encoding: valid_encoding? is true but the encoder
    # cannot convert it, forcing the encode-fallback arm.
    s = "abc".dup.force_encoding(Encoding::UTF_7)
    cleaned = nil
    capture_io do
      cleaned = Rubik::Platform.clean_utf8(s)
    end

    assert_equal "abc", cleaned
    assert_predicate cleaned, :valid_encoding?
  end

  def test_safe_json_generate_double_failure_returns_empty_object
    # Float::INFINITY fails JSON generation twice (cleaned AND fallback pass),
    # driving both rescue arms into the "{}" terminal fallback.
    res = nil
    capture_io do
      res = Rubik::Platform.safe_json_generate({ v: Float::INFINITY })
    end
    assert_equal "{}", res
  end

  def test_safe_json_dump_emits_infinity_literal_where_generate_raises
    # Generate-vs-dump divergence pin: JSON.generate raises on Infinity
    # (driving safe_json_generate to its terminal "{}" arm) but JSON.dump
    # happily emits the bare literal, so the dump path's first pass succeeds
    # and NO rescue arm runs. dump's rescue arms stay uncovered by public
    # input — every value sanitize_for_json_fallback emits is dump-able.
    res = nil
    capture_io do
      res = Rubik::Platform.safe_json_dump({ v: Float::INFINITY })
    end
    assert_equal '{"v":Infinity}', res
  end

  def test_fallback_survives_to_s_failure_on_non_serializable_value
    res = nil
    capture_io do
      res = Rubik::Platform.safe_json_generate({ v: Float::INFINITY, w: ToSBoom.new })
    end
    # The Infinity still poisons the fallback pass, so the terminal "{}" wins;
    # the point is the to_s-raising value took the sanitize-rescue arm without
    # propagating.
    assert_equal "{}", res
  end

  def test_clean_utf8_passthroughs_stay_intact
    assert_equal "plain", Rubik::Platform.clean_utf8("plain")
    assert_equal 42, Rubik::Platform.clean_utf8(42), "non-strings pass through untouched"
  end

  # String subclass whose dup raises: with invalid UTF-8 content and to_s
  # pinned to self, the main chain stays on the subclass and dup explodes,
  # driving the outer scrub-fallback rescue. (Without the to_s pin Ruby 4's
  # String#to_s would return a plain String and the override would never run.)
  class DupBoomInvalidUtf8 < String
    def to_s = self

    def dup = raise IOError, "dup boom"
  end

  def test_clean_utf8_scrub_fallback_survives_dup_failure
    s = DupBoomInvalidUtf8.new("\xff\xfe abc").force_encoding(Encoding::UTF_8)

    cleaned = nil
    capture_io { cleaned = Rubik::Platform.clean_utf8(s) }

    assert_equal " abc", cleaned
    assert_predicate cleaned, :valid_encoding?
  end

  # String subclass whose to_s raises: both the main chain and the inner
  # fallback start with str.to_s, so this drives the outer rescue AND the
  # terminal "" fallback. (Subclass dup/scrub overrides don't travel — Ruby
  # String#dup and #to_s return plain Strings.)
  class ToSBoomString < String
    def to_s = raise ArgumentError, "to_s boom"
  end

  def test_clean_utf8_terminal_fallback_returns_empty_string
    s = ToSBoomString.new("\xff abc").force_encoding(Encoding::UTF_8)

    cleaned = nil
    capture_io { cleaned = Rubik::Platform.clean_utf8(s) }

    assert_equal "", cleaned
  end

  # JSON.dump(target, io) writes through the io — a raising writer drives the
  # dump rescue, the fallback re-dump (same broken io), and the terminal "{}".
  class BrokenJSONIO
    def write(*) = raise IOError, "io boom"

    alias << write
  end

  def test_safe_json_dump_io_failure_falls_back_then_returns_empty_object
    res = nil
    capture_io { res = Rubik::Platform.safe_json_dump({ "a" => 1 }, BrokenJSONIO.new) }

    assert_equal "{}", res
  end
end
