# frozen_string_literal: true

require "minitest/autorun"
require "shellwords"
require "rubik/adapter/node"

class TestNodeAdapterCheckSyntax < Minitest::Test
  def setup
    @adapter = Rubik::Adapter::NodeAdapter.new
  end

  def test_check_syntax_when_unavailable
    process_called = false
    Rubik::Adapter::ProcessRunner.stub(:run, ->(_cmd) { process_called = true; { ok: true } }) do
      @adapter.stub(:available?, false) do
        res = @adapter.check_syntax("src/index.js")
        refute process_called
        refute res[:ok]
        assert_equal 127, res[:exit_code]
        assert_includes res[:output], "node is unavailable on system"
      end
    end
  end

  def test_check_syntax_js_default
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "Syntax OK", exit_code: 0, duration: 0.01 }
    end

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        res = @adapter.check_syntax("src/index.js")
        assert res[:ok]
        assert_equal "node --check src/index.js", captured_cmd
        assert_equal "Syntax OK", res[:output]
      end
    end
  end

  def test_check_syntax_escapes_file_path_with_spaces_and_special_chars
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/my file with spaces & $symbols.js"
    expected_escaped = Shellwords.escape(file_path)

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        @adapter.check_syntax(file_path)
        assert_equal "node --check #{expected_escaped}", captured_cmd
      end
    end
  end

  def test_check_syntax_typescript_tsc_available
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/app.ts"
    escaped = Shellwords.escape(file_path)

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, ->(bin) { bin == "tsc" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "tsc --noEmit #{escaped}", captured_cmd
        end
      end
    end
  end

  def test_check_syntax_tsx_npx_tsc_available
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/Component.tsx"
    escaped = Shellwords.escape(file_path)

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, ->(bin) { bin == "npx" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "npx tsc --noEmit #{escaped}", captured_cmd
        end
      end
    end
  end

  def test_check_syntax_typescript_fallback_node_check
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/app.ts"
    escaped = Shellwords.escape(file_path)

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, false) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "node --check #{escaped}", captured_cmd
        end
      end
    end
  end

  def test_check_syntax_vue_vue_tsc_available
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/App.vue"

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, ->(bin) { bin == "vue-tsc" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "vue-tsc --noEmit", captured_cmd
        end
      end
    end
  end

  def test_check_syntax_vue_npx_available
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: true, output: "", exit_code: 0, duration: 0.01 }
    end

    file_path = "src/App.vue"

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, ->(bin) { bin == "npx" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "npx vue-tsc --noEmit", captured_cmd
        end
      end
    end
  end

  def test_check_syntax_vue_no_checker_available
    process_called = false
    mock_run = lambda do |_cmd|
      process_called = true
      { ok: true }
    end

    file_path = "src/App.vue"

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        Rubik::Runtime::Discovery.stub(:binary_available?, false) do
          res = @adapter.check_syntax(file_path)
          refute process_called
          refute res[:ok]
          assert_equal 127, res[:exit_code]
          assert_includes res[:output], "No syntax checker available for Vue files. Install vue-tsc."
        end
      end
    end
  end

  def test_check_syntax_returns_syntax_error_output_on_failure
    captured_cmd = nil
    mock_run = lambda do |cmd|
      captured_cmd = cmd
      { ok: false, output: "SyntaxError: Unexpected token", exit_code: 1, duration: 0.01 }
    end

    Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
      @adapter.stub(:available?, true) do
        res = @adapter.check_syntax("src/bad.js")
        refute res[:ok]
        assert_equal 1, res[:exit_code]
        assert_equal "SyntaxError: Unexpected token", res[:output]
        assert_equal "node --check src/bad.js", captured_cmd
      end
    end
  end
end
