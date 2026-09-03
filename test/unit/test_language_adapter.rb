# frozen_string_literal: true

require_relative "../test_helper"

class TestLanguageAdapter < Minitest::Test
  def setup
    @registry = Rubik::Adapter::Registry.new
  end

  def test_registry_lists_all_six_adapters
    expected = ["ruby", "python", "go", "rust", "c", "zig"]
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

  def test_swap_replaces_existing_adapter
    old_adapter = @registry.get("ruby")
    new_adapter = Rubik::Adapter::BaseAdapter.new("ruby", "custom_ruby")

    @registry.swap("ruby", new_adapter)

    assert_equal new_adapter, @registry.get("ruby")
    refute_equal old_adapter, @registry.get("ruby")
  end

  def test_swap_case_insensitive
    new_adapter = Rubik::Adapter::BaseAdapter.new("python", "custom_python")

    @registry.swap("PyThOn", new_adapter)

    assert_equal new_adapter, @registry.get("python")
    assert_equal new_adapter, @registry.get("PYTHON")
  end

  def test_swap_with_nil_unregisters_adapter
    refute_nil @registry.get("go")
    assert_includes @registry.list, "go"

    @registry.swap("go", nil)

    assert_nil @registry.get("go")
    refute_includes @registry.list, "go"
  end

  def test_swap_registers_new_language_if_not_present
    assert_nil @registry.get("elixir")
    new_adapter = Rubik::Adapter::BaseAdapter.new("elixir", "elixir")

    @registry.swap("elixir", new_adapter)

    assert_equal new_adapter, @registry.get("elixir")
    assert_includes @registry.list, "elixir"
  end
end
