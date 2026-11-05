# frozen_string_literal: true

require_relative "../test_helper"

# BaseTool#param: the single home for model-supplied argument access.
# Each case pins the byte-compatible
# semantics of the hand-rolled chains it replaces.
class TestToolParam < Minitest::Test
  def tool
    Class.new(Rubik::Tools::BaseTool) do
      def execute(_args = {}) = nil
    end.new(name: "t", description: "t")
  end

  def test_string_key_wins_over_symbol_key
    assert_equal "a", tool.param({ "k" => "a", k: "b" }, :k)
  end

  def test_symbol_key_found_when_no_string_key
    assert_equal "b", tool.param({ k: "b" }, :k)
  end

  def test_false_is_treated_as_absent_like_the_old_or_chains
    # The hand-rolled `args[k] || args[sk] || default` idiom skips false
    # exactly like nil; param keeps that byte-compatible (a model that
    # sends case_sensitive=false falls through to the default, same as
    # before this helper existed).
    assert_equal true, tool.param({ "k" => false }, :k, default: true)
    assert_equal false, tool.param({ "k" => false }, :k, type: :flag)
  end

  def test_alias_chain_tries_keys_in_order_across_spellings
    assert_equal "old", tool.param({ "old_str" => "old", target: "t" }, :target_content, :old_content, :old_str, :target)
    assert_equal "t", tool.param({ target: "t" }, :target_content, :old_content, :old_str, :target)
    assert_nil tool.param({}, :target_content, :old_content, :old_str, :target)
  end

  def test_integer_type_coerces_absent_key_to_zero_like_the_old_idiom
    assert_equal 0, tool.param({}, :offset, type: :integer)
    assert_equal 0, tool.param({ "offset" => nil }, :offset, type: :integer)
    assert_equal 7, tool.param({ offset: "7" }, :offset, type: :integer)
    assert_equal 30, tool.param({}, :limit, type: :integer, default: 30)
  end

  def test_string_and_stripped_string_types
    assert_equal "", tool.param({}, :q, type: :string)
    assert_equal "x", tool.param({ q: " x " }, :q, type: :stripped_string)
    assert_equal "", tool.param({}, :p, type: :stripped_string)
  end

  def test_flag_type_is_strict_equality_with_true
    assert_equal true, tool.param({ "k" => true }, :k, type: :flag)
    assert_equal false, tool.param({ k: "true" }, :k, type: :flag)
    assert_equal false, tool.param({}, :k, type: :flag)
  end

  def test_no_type_returns_the_raw_value
    assert_equal({ nested: 1 }, tool.param({ k: { nested: 1 } }, :k))
    assert_nil tool.param({}, :k)
  end

  def test_nil_args_handled_gracefully
    assert_nil tool.param(nil, :k)
    assert_equal "fallback", tool.param(nil, :k, default: "fallback")
    assert_equal 0, tool.param(nil, :offset, type: :integer)
    assert_equal "", tool.param(nil, :path, type: :stripped_string)
    assert_equal false, tool.param(nil, :flag, type: :flag)
  end
end
