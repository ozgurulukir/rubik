# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

# Regression for #632: test_helper's at_exit used to re-read ENV["HOME"] and
# ENV["RUBIK_TEST_ROOT"] at exit and delete whatever they pointed at. A caller
# that repointed either variable could lose an unrelated directory. Cleanup now
# uses paths captured at setup plus a tmpdir + rubik_test_ prefix guard.
class TestTestHelperTempRootSafety < Minitest::Test
  def test_mutated_home_and_test_root_sentinels_survive_at_exit
    parent = Dir.mktmpdir("rubik_helper_sentinel", Dir.pwd)
    home = File.join(parent, "home")
    root = File.join(parent, "root")
    FileUtils.mkdir_p([home, root])
    File.write(File.join(home, "sentinel.txt"), "keep")
    File.write(File.join(root, "sentinel.txt"), "keep")

    script = <<~RUBY
      require "test_helper"
      at_exit do
        ENV["HOME"] = ENV.fetch("RUBIK_SENTINEL_HOME")
        ENV["RUBIK_TEST_ROOT"] = ENV.fetch("RUBIK_SENTINEL_ROOT")
      end
    RUBY
    env = {
      "RUBIK_COVERAGE" => nil,
      "RUBIK_SENTINEL_HOME" => home,
      "RUBIK_SENTINEL_ROOT" => root
    }
    _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-Itest", "-e", script)

    assert status.success?, "child failed: #{stderr}"
    assert File.file?(File.join(home, "sentinel.txt")), "mutated HOME must not be deleted at exit"
    assert File.file?(File.join(root, "sentinel.txt")), "mutated RUBIK_TEST_ROOT must not be deleted at exit"
  ensure
    FileUtils.remove_entry(parent) if parent && File.directory?(parent)
  end

  def test_inherited_test_root_survives_at_exit
    parent = Dir.mktmpdir("rubik_helper_inherited", Dir.pwd)
    root = File.join(parent, "root")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "sentinel.txt"), "keep")

    env = { "RUBIK_COVERAGE" => nil, "RUBIK_TEST_ROOT" => root }
    _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-Itest", "-e", 'require "test_helper"')

    assert status.success?, "child failed: #{stderr}"
    assert File.file?(File.join(root, "sentinel.txt")), "inherited RUBIK_TEST_ROOT must not be deleted at exit"
  ensure
    FileUtils.remove_entry(parent) if parent && File.directory?(parent)
  end

  def test_captured_test_roots_are_cleaned_up_at_exit
    script = <<~'RUBY'
      require "test_helper"
      puts "CAPTURED_HOME=#{ENV.fetch('HOME')}"
      puts "CAPTURED_ROOT=#{ENV.fetch('RUBIK_TEST_ROOT')}"
    RUBY
    # Unset the inherited root so this child creates (and owns) its own.
    env = { "RUBIK_COVERAGE" => nil, "RUBIK_TEST_ROOT" => nil }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-Itest", "-e", script)

    assert status.success?, "child failed: #{stderr}"
    home = stdout[/^CAPTURED_HOME=(.+)$/, 1]
    root = stdout[/^CAPTURED_ROOT=(.+)$/, 1]
    assert home, "child must report its captured HOME: #{stdout}"
    assert root, "child must report its captured RUBIK_TEST_ROOT: #{stdout}"
    refute File.exist?(home), "captured HOME temp root must be removed at exit"
    refute File.exist?(root), "captured RUBIK_TEST_ROOT temp root must be removed at exit"
  end
end
