# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage: Config listener isolation and scalar-parse fallback
# (audit 2026-09-29, items 6-7). A raising on_change listener must not break
# set/persist, and malformed bracketed scalars persist as raw strings.
class TestConfigListenerIsolation < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubik_cfg_listener")
    @config = Rubik::Config.new(root_dir: @dir)
  end

  def teardown
    remove_temp_dir(@dir)
  end

  def test_raising_listener_does_not_break_set_or_other_listeners
    second_seen = []
    cleanup1 = @config.on_change("buffer.reminder_interval") { raise "boom from listener 1" }
    cleanup2 = @config.on_change("buffer.reminder_interval") { |_k, new_val| second_seen << new_val }

    result = nil
    assert_output(nil, /Config listener failed for 'buffer.reminder_interval'/) do
      result = @config.set("buffer.reminder_interval", 9)
    end

    assert result[:ok], "set should succeed despite the failing listener"
    assert_equal [9], second_seen, "healthy listener must still run"
    assert_equal 9, @config.fetch("buffer.reminder_interval")
  ensure
    cleanup1&.call
    cleanup2&.call
  end

  def test_unbracketed_malformed_scalar_stays_a_string_via_shape_check
    # "{ broken: " is not bracket-shaped: parse_scalar_value returns the raw
    # string without ever attempting YAML.
    result = @config.set("ui.statusline_template", "{ broken: ")
    assert result
    assert_equal "{ broken: ", @config.fetch("ui.statusline_template")
  end

  def test_bracket_shaped_but_invalid_yaml_falls_back_to_raw_string
    # "{a: 'unterminated}" has the bracket shape, so YAML.safe_load runs and
    # raises Psych::SyntaxError — the rescue must fall back to the raw string.
    assert_equal "{a: 'unterminated}", @config.send(:parse_scalar_value, "{a: 'unterminated}")
    assert_equal "[a, 'b]", @config.send(:parse_scalar_value, "[a, 'b]")
  end

  def test_parse_scalar_value_converts_valid_structures
    assert_equal ["a", "b"], @config.send(:parse_scalar_value, "['a', 'b']")
    assert_equal({ "a" => 1 }, @config.send(:parse_scalar_value, "{a: 1}"))
    assert_equal "[a, b", @config.send(:parse_scalar_value, "[a, b"), "unterminated bracket stays a string"
  end
end
