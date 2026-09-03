# frozen_string_literal: true

require_relative "../test_helper"

class TestAdapterBaseFormatCode < Minitest::Test
  def setup
    @adapter = Rubik::Adapter::BaseAdapter.new("base", "base_bin")
    @ruby_adapter = Rubik::Adapter::RubyAdapter.new
  end

  # --- 1. format_code when command cannot be resolved ---
  def test_format_code_returns_unavailable_when_no_cmd_resolved
    result = @adapter.format_code("lib/sample.rb")

    refute result[:ok]
    assert_equal 127, result[:exit_code]
    assert_equal 0.0, result[:duration]
    assert_includes result[:output], "base_bin is unavailable on system"
  end

  # --- 2. format_code when binary is not available ---
  def test_format_code_returns_unavailable_when_binary_not_available
    @adapter.custom_format_cmd = "nonexistent_formatter_cmd_xyz"

    Rubik::Runtime::Discovery.stub :binary_available?, false do
      result = @adapter.format_code("lib/sample.rb")

      refute result[:ok]
      assert_equal 127, result[:exit_code]
      assert_equal 0.0, result[:duration]
      assert_includes result[:output], "base_bin is unavailable on system"
    end
  end

  # --- 3. format_code on successful execution ---
  def test_format_code_successful_execution
    @adapter.custom_format_cmd = "formatter --write"
    dummy_result = {
      ok: true,
      exit_code: 0,
      stdout: "formatted successfully",
      stderr: "",
      output: "formatted successfully",
      duration: 0.12
    }

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, dummy_result do
        result = @adapter.format_code("lib/sample.rb")

        assert result[:ok]
        assert_equal 0, result[:exit_code]
        assert_equal "formatted successfully", result[:output]
        assert_nil result[:diagnostic]
      end
    end
  end

  # --- 4. format_code on failed execution (attaches diagnostic) ---
  def test_format_code_failed_execution_attaches_diagnostic
    @adapter.custom_format_cmd = "formatter --write"
    dummy_failed_result = {
      ok: false,
      exit_code: 1,
      stdout: "",
      stderr: "syntax error on line 5",
      output: "syntax error on line 5",
      duration: 0.08
    }

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, dummy_failed_result do
        result = @adapter.format_code("lib/sample.rb")

        refute result[:ok]
        assert_equal 1, result[:exit_code]
        refute_nil result[:diagnostic]
        assert_kind_of Rubik::Runtime::ExecutionFailure, result[:diagnostic]
        assert_equal :syntax_or_compile_error, result[:diagnostic].category
      end
    end
  end

  # --- 5. resolve_format_cmd tests ---
  def test_resolve_format_cmd_with_custom_cmd_template_percent_s
    @adapter.custom_format_cmd = "rubocop -a %s"
    cmd = @adapter.resolve_format_cmd("lib/rubik.rb")
    assert_equal "rubocop -a lib/rubik.rb", cmd
  end

  def test_resolve_format_cmd_with_custom_cmd_without_template
    @adapter.custom_format_cmd = "prettier --write"
    cmd = @adapter.resolve_format_cmd("src/app.js")
    assert_equal "prettier --write src/app.js", cmd
  end

  def test_resolve_format_cmd_escapes_shell_arguments
    @adapter.custom_format_cmd = "formatter %s"
    cmd = @adapter.resolve_format_cmd("path with spaces/file.rb")
    assert_equal "formatter path\\ with\\ spaces/file.rb", cmd
  end

  def test_resolve_format_cmd_uses_discovery_when_no_custom_cmd
    Rubik::Runtime::Discovery.stub :discover_formatters, ["discovered_fmt"] do
      cmd = @adapter.resolve_format_cmd("lib/sample.rb")
      assert_equal "discovered_fmt lib/sample.rb", cmd
    end
  end

  def test_resolve_format_cmd_fallback_to_default_format_cmd
    Rubik::Runtime::Discovery.stub :discover_formatters, [] do
      cmd = @adapter.resolve_format_cmd("lib/sample.rb")
      assert_nil cmd
    end
  end

  # --- 6. Concrete adapter (RubyAdapter) tests ---
  def test_ruby_adapter_default_format_cmd
    Rubik::Runtime::Discovery.stub :discover_formatters, [] do
      cmd = @ruby_adapter.resolve_format_cmd("lib/foo.rb")
      assert_equal "rubocop -a lib/foo.rb", cmd
    end
  end

  def test_ruby_adapter_format_code_with_mocked_process
    dummy_result = {
      ok: true,
      exit_code: 0,
      stdout: "RuboCop auto-correct complete",
      stderr: "",
      output: "RuboCop auto-correct complete",
      duration: 0.15
    }

    Rubik::Runtime::Discovery.stub :binary_available?, true do
      Rubik::Adapter::ProcessRunner.stub :run, dummy_result do
        result = @ruby_adapter.format_code("lib/foo.rb")

        assert result[:ok]
        assert_equal "RuboCop auto-correct complete", result[:output]
      end
    end
  end
end
