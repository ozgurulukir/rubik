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

  # ---------- lsp_manager: public readers are the only shell path ----------
  # (Prompt policy seam Phase 3: the historical @lsp_manager /
  # @subagent_supervisor ivar reach-ins are gone. A reader-less duck type
  # now degrades to an omitted section — same nil-tolerance as a missing
  # kwarg, instead of reaching into another object's state.)

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

  def lsp_shell(lsp)
    shell = Object.new
    shell.define_singleton_method(:config) { {} }
    shell.define_singleton_method(:commands) { {} }
    shell.define_singleton_method(:lsp_manager) { lsp }
    shell
  end

  def test_shell_reader_supplies_lsp_section_when_kwarg_omitted
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: lsp_shell(fake_lsp_manager(enabled: true)),
      root_dir: Dir.pwd
    )
    assert_includes prompt, "<lsp_status"
  end

  def test_explicit_kwarg_overrides_shell_reader
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: lsp_shell(fake_lsp_manager(enabled: false)),
      lsp_manager: fake_lsp_manager(enabled: true),
      root_dir: Dir.pwd
    )
    assert_includes prompt, "<lsp_status", "the kwarg manager must win over the shell reader"
  end

  def test_reader_less_shell_degrades_to_omitted_lsp_section
    shell = Object.new
    shell.define_singleton_method(:config) { {} }
    shell.define_singleton_method(:commands) { {} }
    # An ivar WITHOUT a reader is deliberately invisible to the prompt
    # layer — no reach-ins, ever again.
    shell.instance_variable_set(:@lsp_manager, fake_lsp_manager(enabled: true))

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default,
      shell: shell,
      root_dir: Dir.pwd
    )
    refute_includes prompt, "<lsp_status"
    refute_includes prompt, "<lsp_diagnostics"
  end
end
