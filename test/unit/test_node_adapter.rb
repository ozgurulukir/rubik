# frozen_string_literal: true

require_relative "../test_helper"

class TestNodeAdapter < Minitest::Test
  def setup
    @adapter = Rubik::Adapter::NodeAdapter.new
  end

  # =========================================================================
  # 1. resolve_format_cmd Tests
  # =========================================================================

  def test_resolve_format_cmd_with_custom_cmd_using_percent_s
    @adapter.custom_format_cmd = "npx prettier --write %s"
    file_path = "src/index.js"

    cmd = @adapter.resolve_format_cmd(file_path)
    assert_equal "npx prettier --write #{Shellwords.escape(file_path)}", cmd
  end

  def test_resolve_format_cmd_with_custom_cmd_without_percent_s
    @adapter.custom_format_cmd = "biome format --write"
    file_path = "src/index.ts"

    cmd = @adapter.resolve_format_cmd(file_path)
    assert_equal "biome format --write #{Shellwords.escape(file_path)}", cmd
  end

  def test_resolve_format_cmd_ignores_empty_or_whitespace_custom_cmd
    @adapter.custom_format_cmd = "   "
    file_path = "src/app.js"

    Rubik::Runtime::Discovery.stub(:discover_formatters, ["npx prettier --write"]) do
      cmd = @adapter.resolve_format_cmd(file_path)
      assert_equal "npx prettier --write #{Shellwords.escape(file_path)}", cmd
    end
  end

  def test_resolve_format_cmd_uses_discovery_when_no_custom_cmd
    file_path = "src/components/button.tsx"
    dir = File.dirname(file_path)

    passed_args = []
    mock_discover = lambda do |root_dir:, lang:|
      passed_args << { root_dir: root_dir, lang: lang }
      ["npx prettier --write"]
    end

    Rubik::Runtime::Discovery.stub(:discover_formatters, mock_discover) do
      cmd = @adapter.resolve_format_cmd(file_path)

      assert_equal "npx prettier --write #{Shellwords.escape(file_path)}", cmd
      assert_equal 1, passed_args.size
      assert_equal dir, passed_args.first[:root_dir]
      assert_equal "node", passed_args.first[:lang]
    end
  end

  def test_resolve_format_cmd_fallback_to_biome_when_discovery_empty
    file_path = "src/utils.js"

    binary_checker = lambda do |bin|
      bin == "biome"
    end

    Rubik::Runtime::Discovery.stub(:discover_formatters, []) do
      Rubik::Runtime::Discovery.stub(:binary_available?, binary_checker) do
        cmd = @adapter.resolve_format_cmd(file_path)
        assert_equal "biome format --write #{Shellwords.escape(file_path)}", cmd
      end
    end
  end

  def test_resolve_format_cmd_fallback_to_prettier_when_biome_unavailable
    file_path = "src/utils.js"

    binary_checker = lambda do |bin|
      bin == "prettier"
    end

    Rubik::Runtime::Discovery.stub(:discover_formatters, []) do
      Rubik::Runtime::Discovery.stub(:binary_available?, binary_checker) do
        cmd = @adapter.resolve_format_cmd(file_path)
        assert_equal "prettier --write #{Shellwords.escape(file_path)}", cmd
      end
    end
  end

  def test_resolve_format_cmd_default_fallback_when_no_binaries_available
    file_path = "src/main.js"

    Rubik::Runtime::Discovery.stub(:discover_formatters, []) do
      Rubik::Runtime::Discovery.stub(:binary_available?, false) do
        cmd = @adapter.resolve_format_cmd(file_path)
        assert_equal "prettier --write #{Shellwords.escape(file_path)}", cmd
      end
    end
  end

  def test_resolve_format_cmd_escapes_special_characters_and_spaces
    file_path = "path with spaces/my file & $script.ts"

    Rubik::Runtime::Discovery.stub(:discover_formatters, []) do
      Rubik::Runtime::Discovery.stub(:binary_available?, false) do
        cmd = @adapter.resolve_format_cmd(file_path)
        expected_escaped = Shellwords.escape(file_path)
        assert_equal "prettier --write #{expected_escaped}", cmd
        assert_includes cmd, expected_escaped
      end
    end
  end

  def test_resolve_format_cmd_escapes_custom_cmd_with_special_characters
    @adapter.custom_format_cmd = "npx prettier --write %s"
    file_path = "path with spaces/my file & $script.ts"

    cmd = @adapter.resolve_format_cmd(file_path)
    expected_escaped = Shellwords.escape(file_path)
    assert_equal "npx prettier --write #{expected_escaped}", cmd
  end

  # =========================================================================
  # 2. available? & runner_for Tests
  # =========================================================================

  def test_available_returns_true_when_node_npm_or_bun_present
    Rubik::Platform.stub(:which, lambda { |cmd| cmd == "node" ? "/usr/bin/node" : nil }) do
      assert @adapter.available?
    end

    Rubik::Platform.stub(:which, lambda { |cmd| cmd == "npm" ? "/usr/bin/npm" : nil }) do
      assert @adapter.available?
    end

    Rubik::Platform.stub(:which, lambda { |cmd| cmd == "bun" ? "/usr/bin/bun" : nil }) do
      assert @adapter.available?
    end
  end

  def test_available_returns_false_when_none_present
    Rubik::Platform.stub(:which, nil) do
      refute @adapter.available?
    end
  end

  # =========================================================================
  # 3. resolve_test_cmd Tests
  # =========================================================================

  def test_resolve_test_cmd_uses_custom_test_cmd_when_set
    @adapter.custom_test_cmd = "npm run test:all"
    assert_equal "npm run test:all", @adapter.resolve_test_cmd

    assert_equal "npm run test:all -- src/foo.test.js", @adapter.resolve_test_cmd(path: "src/foo.test.js")
  end

  def test_resolve_test_cmd_parses_package_json_scripts
    Dir.mktmpdir("node_adapter_test") do |dir|
      pkg_json = File.join(dir, "package.json")

      File.write(pkg_json, JSON.generate({ "scripts" => { "test:run" => "vitest run" } }))
      assert_equal "npm run test:run", @adapter.resolve_test_cmd(dir)

      File.write(pkg_json, JSON.generate({ "scripts" => { "test" => "jest" } }))
      assert_equal "npm test", @adapter.resolve_test_cmd(dir)

      File.write(pkg_json, JSON.generate({ "scripts" => { "test:unit" => "mocha" } }))
      assert_equal "npm run test:unit", @adapter.resolve_test_cmd(dir)
    end
  end

  def test_resolve_test_cmd_detects_lockfiles_for_runner
    Dir.mktmpdir("node_adapter_test") do |dir|
      pkg_json = File.join(dir, "package.json")
      File.write(pkg_json, JSON.generate({ "scripts" => { "test" => "jest" } }))

      FileUtils.touch(File.join(dir, "pnpm-lock.yaml"))
      assert_equal "pnpm test", @adapter.resolve_test_cmd(dir)

      File.delete(File.join(dir, "pnpm-lock.yaml"))
      FileUtils.touch(File.join(dir, "yarn.lock"))
      assert_equal "yarn test", @adapter.resolve_test_cmd(dir)

      File.delete(File.join(dir, "yarn.lock"))
      FileUtils.touch(File.join(dir, "bun.lockb"))
      assert_equal "bun test", @adapter.resolve_test_cmd(dir)
    end
  end

  def test_resolve_test_cmd_handles_malformed_package_json
    Dir.mktmpdir("node_adapter_test") do |dir|
      File.write(File.join(dir, "package.json"), "invalid json {{{")
      assert_equal "npm test", @adapter.resolve_test_cmd(dir)
    end
  end

  def test_resolve_test_cmd_with_percent_s_placeholder
    @adapter.custom_test_cmd = "npx jest --spec %s"
    assert_equal "npx jest --spec src/app.test.js", @adapter.resolve_test_cmd(path: "src/app.test.js")
  end

  # =========================================================================
  # 4. check_syntax Tests
  # =========================================================================

  def test_check_syntax_typescript_with_tsc
    file_path = "src/index.ts"
    executed_cmd = nil

    mock_run = lambda do |cmd|
      executed_cmd = cmd
      { ok: true, output: "", exit_code: 0 }
    end

    @adapter.stub(:available?, true) do
      Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
        Rubik::Runtime::Discovery.stub(:binary_available?, lambda { |b| b == "tsc" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "tsc --noEmit #{Shellwords.escape(file_path)}", executed_cmd
        end
      end
    end
  end

  def test_check_syntax_typescript_with_npx_fallback
    file_path = "src/index.ts"
    executed_cmd = nil

    mock_run = lambda do |cmd|
      executed_cmd = cmd
      { ok: true, output: "", exit_code: 0 }
    end

    @adapter.stub(:available?, true) do
      Rubik::Adapter::ProcessRunner.stub(:run, mock_run) do
        Rubik::Runtime::Discovery.stub(:binary_available?, lambda { |b| b == "npx" }) do
          res = @adapter.check_syntax(file_path)
          assert res[:ok]
          assert_equal "npx tsc --noEmit #{Shellwords.escape(file_path)}", executed_cmd
        end
      end
    end
  end

  def test_check_syntax_vue_when_unavailable
    file_path = "src/App.vue"

    @adapter.stub(:available?, true) do
      Rubik::Runtime::Discovery.stub(:binary_available?, false) do
        res = @adapter.check_syntax(file_path)
        refute res[:ok]
        assert_equal 127, res[:exit_code]
        assert_includes res[:output], "No syntax checker available for Vue files"
      end
    end
  end

  def test_check_syntax_when_adapter_unavailable
    @adapter.stub(:available?, false) do
      res = @adapter.check_syntax("src/index.js")
      refute res[:ok]
      assert_equal 127, res[:exit_code]
      assert_includes res[:output], "node is unavailable"
    end
  end
end
