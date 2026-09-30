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
end
