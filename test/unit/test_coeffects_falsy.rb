# frozen_string_literal: true

require_relative "../test_helper"

class TestCoeffectsFalsy < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @ctx.dispose unless @ctx.disposed?
  end

  def test_context_provides_and_requires_falsy_boolean
    @ctx.provide(:sandbox_enabled, false)

    assert_equal false, @ctx.require(:sandbox_enabled)
    assert_equal false, @ctx.require("sandbox_enabled")
    assert_equal false, @ctx.get(:sandbox_enabled)
    assert_equal false, @ctx.get(:sandbox_enabled, true)
    assert @ctx.has?(:sandbox_enabled)
    assert @ctx.has?("sandbox_enabled")
    assert_equal false, @ctx.resolve("sandbox_enabled")
  end

  def test_coeffects_get_and_resolve_handle_false
    @ctx.provide(:dry_run, false)

    assert_equal false, Rubik::Coeffects.get(@ctx, :dry_run)
    assert_equal false, Rubik::Coeffects.get(@ctx, "dry_run")
    assert_equal false, Rubik::Coeffects.resolve(@ctx, :dry_run, true)
    assert_equal :fallback, Rubik::Coeffects.resolve(@ctx, :missing_key, :fallback)
  end

  def test_child_context_inherits_falsy_values
    @ctx.provide(:flag, false)
    child = @ctx.extend

    assert_equal false, child.require(:flag)
    assert_equal false, child.get(:flag)
    assert_equal false, child.get(:flag, true)
    assert child.has?(:flag)
    assert_equal false, child.resolve("flag")

    child.provide(:flag, true)
    assert_equal true, child.get(:flag)
    assert_equal false, @ctx.get(:flag)

    child.dispose
  end

  def test_child_overriding_truthy_with_false
    @ctx.provide(:flag, true)
    child = @ctx.extend
    child.provide(:flag, false)

    assert_equal false, child.require(:flag)
    assert_equal false, child.get(:flag)
    assert_equal false, child.get(:flag, true)
    assert child.has?(:flag)
    assert_equal true, @ctx.get(:flag)

    child.dispose
  end

  def test_missing_and_nil_coeffects
    assert_nil @ctx.get(:absent)
    assert_equal :default, @ctx.get(:absent, :default)
    refute @ctx.has?(:absent)
    assert_nil @ctx.resolve("absent")

    assert_raises(Rubik::Runtime::CoeffectMissingError) do
      @ctx.require(:absent)
    end
  end
end
