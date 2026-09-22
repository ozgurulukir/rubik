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

    # 1. Execute !model command without flags -> Session only
    shell.execute_input("!model openai/gpt-4o-mini")
    assert_includes out.string, "Switched default model to openai/gpt-4o-mini"
    assert_includes out.string, "[Session only]"

    # Reloading config from disk should not have persisted session-only change
    cfg_ephemeral = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    refute_equal "gpt-4o-mini", cfg_ephemeral.model_spec(:default)["name"]

    # 2. Execute !model command with -g flag -> Global persistence
    out.reopen
    shell.execute_input("!model openai/gpt-4o-mini -g")
    assert_includes out.string, "Switched default model to openai/gpt-4o-mini"
    assert_includes out.string, "[System level (~/.rubik/config.yml)]"

    # Verify persistent storage on disk
    cfg_reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal "openai", cfg_reloaded.model_spec(:default)["provider"]
    assert_equal "gpt-4o-mini", cfg_reloaded.model_spec(:default)["name"]
  end

  def test_set_reports_the_persist_outcome_for_every_scope
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)

    # Session-only: no disk write attempted, plain success
    assert_equal({ ok: true }, cfg.set("repair.max_attempts", 5, persist: :session))
    assert_equal({ ok: true }, cfg.set("repair.max_attempts", 5))

    # Disk write: success carries the path and scope
    global = cfg.set("repair.max_attempts", 7, persist: :global)
    assert global[:ok]
    assert_equal :global, global[:scope]
    assert_equal File.join(@temp_home, ".rubik", "config.yml"), global[:path]

    spec_res = cfg.set_model_spec(:fast, provider: "ollama", name: "llama3", persist: :global)
    assert spec_res[:ok]
    assert_equal :global, spec_res[:scope]
  end

  def test_set_reports_a_failed_disk_write_instead_of_losing_it
    # A root_dir that is a regular file makes every project write fail
    blocker = File.join(@temp_root, "blocker")
    File.write(blocker, "not a directory")
    cfg = Rubik::Config.new(root_dir: blocker, home_dir: @temp_home)

    res = cfg.set("repair.max_attempts", 5, persist: :project)

    refute res[:ok]
    assert res[:error]
    # The in-memory change is still applied — only the disk write failed.
    assert_equal 5, cfg.fetch("repair.max_attempts")
  end

  def test_shell_config_set_and_paths
    out = StringIO.new
    cfg = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: cfg, output: out)

    # 1. Session-only set: !config set repair.max_attempts 5
    shell.execute_input("!config set repair.max_attempts 5")
    assert_includes out.string, "Config 'repair.max_attempts' updated to '5' [Session only]"
    assert_equal 5, shell.config.fetch("repair.max_attempts")

    # 2. Explicit global set: !config set repair.max_attempts 5 -g
    out.reopen
    shell.execute_input("!config set repair.max_attempts 5 -g")
    assert_includes out.string, "Config 'repair.max_attempts' updated to '5' [System level (~/.rubik/config.yml)]"

    cfg_reloaded = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal 5, cfg_reloaded.fetch("repair.max_attempts")

    # Verbless usage produces smart guidance: !config lsp.enabled true
    out.reopen
    shell.execute_input("!config lsp.enabled true")
    assert_includes out.string, "[Rubik::Config] Geçersiz kullanım."
    assert_includes out.string, "!config set lsp.enabled true"
    assert_includes out.string, "!config get lsp.enabled"

    # Verbless single key usage produces smart guidance: !config lsp.enabled
    out.reopen
    shell.execute_input("!config lsp.enabled")
    assert_includes out.string, "[Rubik::Config] Geçersiz kullanım."
    assert_includes out.string, "!config get lsp.enabled"

    # Explicit set: !config set lsp.enabled true
    out.reopen
    shell.execute_input("!config set lsp.enabled true")
    assert_includes out.string, "Config 'lsp.enabled' updated to 'true'"
    assert_equal true, shell.config.fetch("lsp.enabled")

    # Explicit get: !config get lsp.enabled
    out.reopen
    shell.execute_input("!config get lsp.enabled")
    assert_includes out.string, "lsp.enabled = true"

    # Paths: !config path
    out.reopen
    shell.execute_input("!config path")
    assert_includes out.string, "Global Config"
    assert_includes out.string, "Project Config"

    # List: !config list
    out.reopen
    shell.execute_input("!config list lsp")
    assert_includes out.string, "lsp.enabled"
  end
end
