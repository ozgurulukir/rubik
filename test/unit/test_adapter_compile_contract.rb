# frozen_string_literal: true

require_relative "../test_helper"

class TestAdapterCompileContract < Minitest::Test
  def test_base_default_compile_is_noop
    adapter = Rubik::Adapter::BaseAdapter.new("dummy", "definitely-missing-bin-xyz")
    res = adapter.compile(Dir.pwd)

    assert res[:ok]
    assert_equal 0, res[:exit_code]
    assert_includes res[:output], "no compilation"
  end

  def test_interpreted_adapters_ride_the_base_default
    [Rubik::Adapter::RubyAdapter.new, Rubik::Adapter::PythonAdapter.new].each do |adapter|
      assert_equal Rubik::Adapter::BaseAdapter, adapter.method(:compile).owner,
                   "#{adapter.class} must not carry a local no-op override"
      assert adapter.compile(Dir.pwd)[:ok]
    end
  end

  def test_compiled_language_adapters_still_override
    ["C", "Zig", "Go", "Rust"].each do |lang|
      klass = Rubik::Adapter.const_get("#{lang}Adapter")
      refute_equal Rubik::Adapter::BaseAdapter, klass.instance_method(:compile).owner,
                   "#{klass} must keep its real compile implementation"
    end
  end

  def test_check_syntax_remains_abstract_on_base
    adapter = Rubik::Adapter::BaseAdapter.new("ruby", "ruby")
    assert adapter.available?
    assert_raises(NotImplementedError) { adapter.check_syntax("some.rb") }
  end
end
