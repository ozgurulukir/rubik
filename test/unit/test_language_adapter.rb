# frozen_string_literal: true

require_relative "../test_helper"

class TestLanguageAdapter < Minitest::Test
  def setup
    @registry = Rubik::Adapter::Registry.new
  end

  def test_registry_lists_all_six_adapters
    expected = %w[ruby python go rust c zig]
    expected.each do |lang|
      assert_includes @registry.list, lang
      refute_nil @registry.get(lang)
    end
  end

  def test_ruby_adapter_check_syntax
    temp_file = File.join(Dir.mktmpdir, "valid.rb")
    File.write(temp_file, "def foo; 42; end\n")

    adapter = @registry.get("ruby")
    res = adapter.check_syntax(temp_file)

    assert res[:ok], "Ruby syntax check should pass"
    assert res[:duration] >= 0
  end

  def test_unavailable_adapter_returns_graceful_result
    fake_adapter = Rubik::Adapter::BaseAdapter.new("fake", "non_existent_binary_xyz")
    res = fake_adapter.check_syntax("some_file")

    refute res[:ok]
    assert_equal 127, res[:exit_code]
    assert_includes res[:output], "is unavailable on system"
  end
end
