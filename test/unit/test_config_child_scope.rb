# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"

class TestConfigChildScope < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik-scope-root-")
    @temp_home = Dir.mktmpdir("rubik-scope-home-")
    @parent_config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
  end

  def teardown
    FileUtils.remove_entry_secure(@temp_root) if @temp_root && File.directory?(@temp_root)
    FileUtils.remove_entry_secure(@temp_home) if @temp_home && File.directory?(@temp_home)
  end

  def test_child_scope_inheritance_and_shadowing
    @parent_config.set("agent.max_steps", 25)
    child_config = @parent_config.extend("agent.max_steps" => 10, "context.max_tokens" => 8_192)

    # Overridden values in child
    assert_equal 10, child_config.fetch("agent.max_steps")
    assert_equal 8_192, child_config.fetch("context.max_tokens")

    # Parent remains unaffected
    assert_equal 25, @parent_config.fetch("agent.max_steps")
    assert_equal 32_768, @parent_config.fetch("context.max_tokens", 32_768)

    # Non-overridden values fall back to parent
    assert_equal 3, child_config.fetch("repair.max_attempts")
  end

  def test_child_scope_mutations_never_pollute_parent
    child_config = @parent_config.extend
    child_config.set("experimental_flag", "child_value")

    assert_equal "child_value", child_config.fetch("experimental_flag")
    assert_nil @parent_config.fetch("experimental_flag")
  end

  def test_child_scope_persistence_is_fail_closed
    child_config = @parent_config.extend

    err_project = assert_raises(ArgumentError) do
      child_config.set("foo", "bar", persist: :project)
    end
    assert_includes err_project.message, "cannot persist to disk"

    err_global = assert_raises(ArgumentError) do
      child_config.set("foo", "bar", persist: :global)
    end
    assert_includes err_global.message, "cannot persist to disk"
  end

  def test_child_scope_revertible_inverses_on_context_dispose
    ctx = Rubik::Runtime::Context.new
    @parent_config.set("counter", 100)

    @parent_config.set_revertible(ctx, "counter", 200)
    assert_equal 200, @parent_config.fetch("counter")

    # Disposing context executes inverse and rolls back value
    ctx.dispose
    assert_equal 100, @parent_config.fetch("counter")
  end
end
