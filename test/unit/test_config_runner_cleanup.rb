# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class TestConfigRunnerCleanup < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik-runner-cleanup-")
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_dir) if @temp_dir && File.directory?(@temp_dir)
  end

  def test_runner_unregisters_listeners_on_dispose
    config = Rubik::Config.new(root_dir: @temp_dir)
    initial_listener_count = config.instance_variable_get(:@listeners).size

    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config)
    assert_equal initial_listener_count + 2, config.instance_variable_get(:@listeners).size

    runner.dispose
    assert_equal initial_listener_count, config.instance_variable_get(:@listeners).size
  end

  def test_context_dispose_automatically_triggers_runner_dispose
    config = Rubik::Config.new(root_dir: @temp_dir)
    ctx = Rubik::Runtime::Context.new
    initial_listener_count = config.instance_variable_get(:@listeners).size

    _runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config, context: ctx)
    assert_equal initial_listener_count + 2, config.instance_variable_get(:@listeners).size

    ctx.dispose
    assert_equal initial_listener_count, config.instance_variable_get(:@listeners).size
  end

  def test_zero_listener_leak_under_repeated_creation_cycles
    config = Rubik::Config.new(root_dir: @temp_dir)
    baseline_listeners = config.instance_variable_get(:@listeners).size

    50.times do
      sub_ctx = Rubik::Runtime::Context.new
      Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config, context: sub_ctx)
      sub_ctx.dispose
    end

    assert_equal baseline_listeners, config.instance_variable_get(:@listeners).size
  end
end
