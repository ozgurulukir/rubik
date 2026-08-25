# frozen_string_literal: true

require_relative "../test_helper"

# Tests for PR-F: ContextBuilder decoupled from REPL::Shell.
# `shell:` is kept for backward compatibility (deprecated); new
# `config:` and `commands:` kwargs are the preferred path.
class TestContextBuilderDecoupling < Minitest::Test
  # ---------- New API: config: and commands: ----------

  def test_build_system_prompt_accepts_config_and_commands_kwargs
    fake_config = { "buffer.auto_apply" => "auto" }
    commands = { "list" => { description: "List things", custom: true } }

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      tool_schemas: [],
      config: fake_config,
      commands: commands,
      root_dir: Dir.pwd
    )
    assert_kind_of String, prompt
    assert_includes prompt, "auto"
    assert_includes prompt, "list"
  end

  def test_build_system_prompt_with_only_config_uses_auto_apply_from_config
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      config: { "buffer.auto_apply" => "auto" },
      root_dir: Dir.pwd
    )
    assert_includes prompt, "auto"
  end

  def test_build_system_prompt_with_only_commands_renders_them
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      commands: { "deploy" => { description: "Deploy to prod", custom: true } },
      root_dir: Dir.pwd
    )
    assert_includes prompt, "deploy"
  end

  def test_build_system_prompt_with_neither_works
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      root_dir: Dir.pwd
    )
    assert_kind_of String, prompt
    # Default auto_apply is "manual"
    assert_includes prompt, "manual"
  end

  # ---------- Backward compat: shell: keyword still works ----------

  def test_build_system_prompt_with_shell_kwarg_still_works
    # A minimal shell stub with .config and .commands
    shell = Object.new
    config = { "buffer.auto_apply" => "manual" }
    commands = { "test_cmd" => { description: "Run tests", custom: true } }
    shell.define_singleton_method(:config) { config }
    shell.define_singleton_method(:commands) { commands }

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      root_dir: Dir.pwd
    )
    assert_includes prompt, "test_cmd"
  end

  def test_build_system_prompt_with_shell_only_config_no_commands
    shell = Object.new
    config = { "buffer.auto_apply" => "auto" }
    shell.define_singleton_method(:config) { config }
    # No commands method

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      root_dir: Dir.pwd
    )
    assert_includes prompt, "auto"
  end

  def test_build_system_prompt_config_takes_precedence_over_shell_config
    shell = Object.new
    shell.define_singleton_method(:config) { { "buffer.auto_apply" => "manual" } }
    shell.define_singleton_method(:commands) { {} }

    # New config: wins
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      config: { "buffer.auto_apply" => "auto" },
      root_dir: Dir.pwd
    )
    assert_includes prompt, "auto"
  end

  # ---------- lsp_manager kwarg overrides shell iv ----------

  # A minimal LSP stub. The real Rubik::LSP::* has #enabled? and friends;
  # we only need methods the ContextBuilder calls.
  def fake_lsp_manager(enabled: true)
    Class.new do
      define_method(:enabled?) { enabled }
      define_method(:running?) { enabled }
      define_method(:servers) { [] }
      define_method(:status_summary) { { servers: {}, running_count: 0, total_diagnostics: 0 } }
      define_method(:all_diagnostics) { {} }
    end.new
  end

  def test_lsp_manager_falls_back_to_shell_iv_when_not_provided
    shell = Object.new
    shell.define_singleton_method(:config) { {} }
    shell.define_singleton_method(:commands) { {} }
    shell.instance_variable_set(:@lsp_manager, fake_lsp_manager)

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      root_dir: Dir.pwd
    )
    assert_match(/lsp|LSP/, prompt)
  end

  def test_lsp_manager_kwarg_overrides_shell_iv
    shell = Object.new
    shell.define_singleton_method(:config) { {} }
    shell.define_singleton_method(:commands) { {} }
    shell.instance_variable_set(:@lsp_manager, fake_lsp_manager)

    provided_lsp = fake_lsp_manager
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      lsp_manager: provided_lsp,
      root_dir: Dir.pwd
    )
    assert_match(/lsp|LSP/, prompt)
  end
end
