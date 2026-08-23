# frozen_string_literal: true

require_relative "../test_helper"

class TestContextScanner < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    File.write(File.join(@temp_dir, ".gitignore"), "node_modules/\n*.log\n")
    FileUtils.mkdir_p(File.join(@temp_dir, "node_modules"))
    File.write(File.join(@temp_dir, "node_modules", "package.json"), "{}")

    FileUtils.mkdir_p(File.join(@temp_dir, "src"))
    File.write(File.join(@temp_dir, "src", "main.go"), "package main")
    File.write(File.join(@temp_dir, "build.zig"), "// zig build")
    File.write(File.join(@temp_dir, "app.log"), "log line")
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_respects_gitignore
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    files = scanner.scan

    refute_includes files.keys, "node_modules/package.json"
    refute_includes files.keys, "app.log"
    assert_includes files.keys, "src/main.go"
    assert_includes files.keys, "build.zig"
  end

  def test_detects_multiple_languages
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    files = scanner.scan
    langs = scanner.detect_languages(files)

    assert_includes langs, "go"
    assert_includes langs, "zig"
  end
end
