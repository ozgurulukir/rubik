# frozen_string_literal: true

require_relative "../test_helper"

class TestConfigPersistence < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
  end

  def teardown
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_global_config_persistence_and_retention
    # 1. First session: Set global default model
    cfg1 = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    cfg1.set_model_spec(:default, provider: "openai", name: "gpt-4o", persist: :global)

    # Verify file was written
    global_file = File.join(@temp_home, ".rubik", "config.yml")
    assert File.exist?(global_file)

    # 2. Second session / Next run: Load config freshly
    cfg2 = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    spec = cfg2.model_spec(:default)
    assert_equal "openai", spec["provider"]
    assert_equal "gpt-4o", spec["name"]
  end

  def test_project_config_overrides_global_config
    # 1. Set global default
    cfg_global = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    cfg_global.set_model_spec(:default, provider: "ollama", name: "llama3", persist: :global)

    # 2. Set project-specific override
    cfg_project = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    cfg_project.set_model_spec(:default, provider: "anthropic", name: "claude-3-7-sonnet", persist: :project)

    project_file = File.join(@temp_root, ".rubik", "config.yml")
    assert File.exist?(project_file)

    # 3. Next session in the same project gets project override
    cfg_loaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "anthropic", cfg_loaded.model_spec(:default)["provider"]
    assert_equal "claude-3-7-sonnet", cfg_loaded.model_spec(:default)["name"]

    # 4. Another project in a different directory gets the global config
    other_root = Dir.mktmpdir("rubik_other")
    cfg_other = Rubik::Config.new(root_dir: other_root, home_dir: @temp_home)
    assert_equal "ollama", cfg_other.model_spec(:default)["provider"]
    assert_equal "llama3", cfg_other.model_spec(:default)["name"]
    FileUtils.remove_entry(other_root)
  end

  def test_shell_model_command_auto_persists
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out)

    # Execute !model command
    shell.execute_input("!model openai/gpt-4o-mini")
    assert_includes out.string, "Switched default model to openai/gpt-4o-mini"
    assert_includes out.string, "[Saved to global config]"

    # Verify persistent storage
    cfg_reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "openai", cfg_reloaded.model_spec(:default)["provider"]
    assert_equal "gpt-4o-mini", cfg_reloaded.model_spec(:default)["name"]
  end

  def test_shell_config_set_and_paths
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out)

    shell.execute_input("!config set repair.max_attempts 5")
    assert_includes out.string, "Config 'repair.max_attempts' updated to '5' [Saved to global config]"

    cfg_reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "5", cfg_reloaded.fetch("repair.max_attempts")
  end
end
