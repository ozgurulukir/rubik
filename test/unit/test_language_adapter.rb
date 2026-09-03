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

  def test_resolve_test_cmd_uses_custom_test_cmd_when_set
    adapter = Rubik::Adapter::BaseAdapter.new("fake", "binary")
    adapter.custom_test_cmd = "bundle exec rspec"

    assert_equal "bundle exec rspec", adapter.resolve_test_cmd
  end

  def test_resolve_test_cmd_ignores_empty_or_whitespace_custom_test_cmd
    adapter = Rubik::Adapter::RubyAdapter.new
    adapter.custom_test_cmd = "   "

    Rubik::Runtime::Discovery.stub(:discover_test_runners, []) do
      assert_equal "rake test", adapter.resolve_test_cmd
    end
  end

  def test_resolve_test_cmd_returns_discovered_runner_when_available
    adapter = Rubik::Adapter::RubyAdapter.new

    Rubik::Runtime::Discovery.stub(:discover_test_runners, ["bundle exec rspec", "rake test"]) do
      assert_equal "bundle exec rspec", adapter.resolve_test_cmd
    end
  end

  def test_resolve_test_cmd_falls_back_to_defaults_when_nothing_discovered
    base_adapter = Rubik::Adapter::BaseAdapter.new("base", "basebin")
    ruby_adapter = Rubik::Adapter::RubyAdapter.new
    python_adapter = Rubik::Adapter::PythonAdapter.new
    go_adapter = Rubik::Adapter::GoAdapter.new
    rust_adapter = Rubik::Adapter::RustAdapter.new
    zig_adapter = Rubik::Adapter::ZigAdapter.new
    c_adapter = Rubik::Adapter::CAdapter.new

    Rubik::Runtime::Discovery.stub(:discover_test_runners, []) do
      assert_nil base_adapter.resolve_test_cmd
      assert_equal "rake test", ruby_adapter.resolve_test_cmd
      assert_equal "pytest", python_adapter.resolve_test_cmd
      assert_equal "go test ./...", go_adapter.resolve_test_cmd
      assert_equal "cargo test", rust_adapter.resolve_test_cmd
      assert_equal "zig test", zig_adapter.resolve_test_cmd
      assert_equal "ctest", c_adapter.resolve_test_cmd
    end
  end

  def test_resolve_test_cmd_passes_root_dir_to_discovery
    adapter = Rubik::Adapter::RubyAdapter.new
    custom_root = "/custom/project/root"
    passed_args = []

    mock_discovery = lambda do |root_dir:, lang:|
      passed_args << { root_dir: root_dir, lang: lang }
      []
    end

    Rubik::Runtime::Discovery.stub(:discover_test_runners, mock_discovery) do
      adapter.resolve_test_cmd(custom_root)
    end

    assert_equal 1, passed_args.size
    assert_equal custom_root, passed_args.first[:root_dir]
    assert_equal "ruby", passed_args.first[:lang]
  end
end
