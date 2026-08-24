# frozen_string_literal: true

require_relative "../test_helper"

class TestRuntimeDiscovery < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_discovery_test")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_lsp_candidates_lookup
    candidates = Rubik::Runtime::Discovery.lsp_candidates("ruby")
    assert_includes candidates, "solargraph stdio"
    assert_includes candidates, "typeprof --lsp --stdio"

    py_candidates = Rubik::Runtime::Discovery.lsp_candidates("PYTHON")
    assert_includes py_candidates, "pylsp"
    assert_includes py_candidates, "pyright-langserver --stdio"

    rust_candidates = Rubik::Runtime::Discovery.lsp_candidates("rust")
    assert_equal ["rust-analyzer"], rust_candidates

    assert_empty Rubik::Runtime::Discovery.lsp_candidates("non_existent_lang")
  end

  def test_binary_available
    assert Rubik::Runtime::Discovery.binary_available?("ruby")
    assert Rubik::Runtime::Discovery.binary_available?(Rubik::Platform.windows? ? "cmd" : "sh")
    assert Rubik::Runtime::Discovery.binary_available?("ruby -v")
    refute Rubik::Runtime::Discovery.binary_available?("non_existent_binary_xyz_98765")
    refute Rubik::Runtime::Discovery.binary_available?(nil)
    refute Rubik::Runtime::Discovery.binary_available?("")
  end

  def test_detect_primary_language_by_markers
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    assert_equal "ruby", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "Gemfile"))
    FileUtils.touch(File.join(@temp_dir, "Cargo.toml"))
    assert_equal "rust", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "Cargo.toml"))
    FileUtils.touch(File.join(@temp_dir, "go.mod"))
    assert_equal "go", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "go.mod"))
    FileUtils.touch(File.join(@temp_dir, "pyproject.toml"))
    assert_equal "python", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "pyproject.toml"))
    FileUtils.touch(File.join(@temp_dir, "build.zig"))
    assert_equal "zig", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "build.zig"))
    FileUtils.touch(File.join(@temp_dir, "CMakeLists.txt"))
    assert_equal "c", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)
  end

  def test_test_runner_candidates_resolution
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    candidates = Rubik::Runtime::Discovery.test_runner_candidates("ruby", root_dir: @temp_dir)
    assert_includes candidates, "bundle exec rspec"
    assert_includes candidates, "bundle exec rake test"
    assert_includes candidates, "rake test"

    FileUtils.touch(File.join(@temp_dir, "Cargo.toml"))
    rust_candidates = Rubik::Runtime::Discovery.test_runner_candidates("rust", root_dir: @temp_dir)
    assert_includes rust_candidates, "cargo nextest run"
    assert_includes rust_candidates, "cargo test"
  end

  def test_discover_test_runners_filters_available_binaries
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    runners = Rubik::Runtime::Discovery.discover_test_runners(root_dir: @temp_dir, lang: "ruby")
    # All returned runners must have valid binaries
    runners.each do |runner_cmd|
      assert Rubik::Runtime::Discovery.binary_available?(runner_cmd), "Runner '#{runner_cmd}' should have binary available"
    end
  end

  def test_discover_formatters
    formatters = Rubik::Runtime::Discovery.discover_formatters(root_dir: @temp_dir, lang: "ruby")
    formatters.each do |fmt|
      assert Rubik::Runtime::Discovery.binary_available?(fmt), "Formatter '#{fmt}' should be available"
    end
  end

  def test_probe_lsp_finds_available_candidate
    probed = Rubik::Runtime::Discovery.probe_lsp("ruby", root_dir: @temp_dir)
    if probed
      assert Rubik::Runtime::Discovery.binary_available?(probed)
    end

    custom_probed = Rubik::Runtime::Discovery.probe_lsp("ruby", root_dir: @temp_dir, custom_cmd: "ruby -e 'puts 1'")
    assert_equal "ruby -e 'puts 1'", custom_probed
  end

  def test_detect_primary_language_by_typescript_and_javascript_markers
    FileUtils.touch(File.join(@temp_dir, "tsconfig.json"))
    assert_equal "typescript", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)

    FileUtils.rm(File.join(@temp_dir, "tsconfig.json"))
    FileUtils.touch(File.join(@temp_dir, "package.json"))
    assert_equal "javascript", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)
  end

  def test_detect_primary_language_by_file_extensions_fallback
    File.write(File.join(@temp_dir, "main.rs"), "fn main() {}")
    File.write(File.join(@temp_dir, "lib.rs"), "pub fn test() {}")
    assert_equal "rust", Rubik::Runtime::Discovery.detect_primary_language(@temp_dir)
  end

  def test_test_runner_candidates_for_javascript_package_managers
    FileUtils.touch(File.join(@temp_dir, "pnpm-lock.yaml"))
    candidates = Rubik::Runtime::Discovery.test_runner_candidates("typescript", root_dir: @temp_dir)
    assert_includes candidates, "pnpm test"
    assert_includes candidates, "npm test"
  end
end
