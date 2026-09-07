# frozen_string_literal: true

require_relative "../test_helper"

class TestDiscoveryTestRunner < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_discovery_test")
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_ruby_candidates_without_spec_dir_prioritizes_rake_test
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    FileUtils.mkdir_p(File.join(@temp_dir, "test"))

    candidates = Rubik::Runtime::Discovery.test_runner_candidates("ruby", root_dir: @temp_dir)

    # Without spec/ directory, rake test must come before rspec
    assert_equal "bundle exec rake test", candidates.first
    assert_includes candidates, "rake test"
    assert_includes candidates, "bundle exec rspec"
    assert candidates.index("bundle exec rake test") < candidates.index("bundle exec rspec")
  end

  def test_ruby_candidates_with_spec_dir_prioritizes_rspec
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    FileUtils.mkdir_p(File.join(@temp_dir, "spec"))

    candidates = Rubik::Runtime::Discovery.test_runner_candidates("ruby", root_dir: @temp_dir)

    # With spec/ directory present, rspec comes first
    assert_equal "bundle exec rspec", candidates.first
    assert_includes candidates, "bundle exec rake test"
  end

  def test_ruby_candidates_with_project_test_command_override
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    FileUtils.mkdir_p(File.join(@temp_dir, "spec"))

    config = { "project" => { "test_command" => "bundle exec m -r" } }
    candidates = Rubik::Runtime::Discovery.test_runner_candidates("ruby", root_dir: @temp_dir, config: config)

    assert_equal "bundle exec m -r", candidates.first
  end

  def test_ruby_candidates_with_adapter_test_command_override
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))

    config = { "adapter" => { "ruby" => { "test_command" => "bin/test" } } }
    candidates = Rubik::Runtime::Discovery.test_runner_candidates("ruby", root_dir: @temp_dir, config: config)

    assert_equal "bin/test", candidates.first
  end

  def test_adapter_base_respects_config_test_command
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    adapter = Rubik::Adapter::RubyAdapter.new
    adapter.config = { "project" => { "test_command" => "rake test:fast" } }

    # Stub binary_available? for rake test:fast
    Rubik::Runtime::Discovery.stub(:binary_available?, true) do
      resolved = adapter.resolve_test_cmd(@temp_dir)
      assert_equal "rake test:fast", resolved
    end
  end

  def test_discover_test_runners_finds_local_executable_in_root_dir
    FileUtils.touch(File.join(@temp_dir, "Gemfile"))
    script_path = File.join(@temp_dir, "bin", "test")
    FileUtils.mkdir_p(File.dirname(script_path))
    File.write(script_path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, script_path)

    config = { "project" => { "test_command" => "bin/test" } }
    runners = Rubik::Runtime::Discovery.discover_test_runners(root_dir: @temp_dir, lang: "ruby", config: config)

    assert_includes runners, "bin/test"
    assert_equal "bin/test", runners.first
  end
end
