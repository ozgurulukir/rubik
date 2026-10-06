# frozen_string_literal: true

require_relative "../test_helper"

# Tests for PR-F: ContextBuilder decoupled from REPL::Shell.
# The builders accept ONLY a `services:` view (a frozen Prompt::Services,
# lib/rubik/prompt/services.rb). Shell integration happens exactly once,
# in Services.from_shell at the composition boundary — the builders never
# see a shell.
class TestContextBuilderDecoupling < Minitest::Test
  # ---------- Explicit services views ----------

  def test_services_view_carries_config_and_commands
    services = Rubik::Prompt::Services.new(
      config: { "buffer.auto_apply" => "auto" },
      commands: { "list" => { description: "List things", custom: true } }
    )

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      mode: :default, tool_schemas: [], services: services
    )
    assert_kind_of String, prompt
    assert_includes prompt, "auto"
    assert_includes prompt, "list"
  end

  def test_view_with_only_config_uses_auto_apply_from_config
    services = Rubik::Prompt::Services.new(config: { "buffer.auto_apply" => "auto" })
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "auto"
  end

  def test_view_with_only_commands_renders_them
    services = Rubik::Prompt::Services.new(
      commands: { "deploy" => { description: "Deploy to prod", custom: true } }
    )
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "deploy"
  end

  def test_prompt_renders_with_no_services_at_all
    services = Rubik::Prompt::Services.new
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_kind_of String, prompt
    # Default auto_apply is "manual"
    assert_includes prompt, "manual"
  end

  # ---------- Services.from_shell: the single shell-aware path ----------

  def test_from_shell_collects_public_readers
    shell = Object.new
    config = { "buffer.auto_apply" => "manual" }
    commands = { "test_cmd" => { description: "Run tests", custom: true } }
    shell.define_singleton_method(:config) { config }
    shell.define_singleton_method(:commands) { commands }

    services = Rubik::Prompt::Services.from_shell(shell)
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "test_cmd"
  end

  def test_from_shell_with_only_config_reader
    shell = Object.new
    shell.define_singleton_method(:config) { { "buffer.auto_apply" => "auto" } }
    # No commands reader

    services = Rubik::Prompt::Services.from_shell(shell)
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "auto"
  end

  def test_from_shell_overrides_beat_shell_readers
    shell = Object.new
    shell.define_singleton_method(:config) { { "buffer.auto_apply" => "manual" } }
    shell.define_singleton_method(:commands) { {} }

    services = Rubik::Prompt::Services.from_shell(
      shell,
      config: { "buffer.auto_apply" => "auto" }
    )
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "auto", "the override must win over the shell reader"
  end

  # ---------- lsp_manager: public readers are the only shell path ----------
  # (Prompt policy seam Phase 3: the historical @lsp_manager /
  # @subagent_supervisor ivar reach-ins are gone. A reader-less duck type
  # now degrades to an omitted section — same nil-tolerance as an
  # unsatisfied slot, instead of reaching into another object's state.)

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

  def test_from_shell_reader_supplies_lsp_section
    services = Rubik::Prompt::Services.from_shell(lsp_shell(fake_lsp_manager(enabled: true)))
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "<lsp_status"
  end

  def test_from_shell_override_wins_over_shell_reader
    services = Rubik::Prompt::Services.from_shell(
      lsp_shell(fake_lsp_manager(enabled: false)),
      lsp_manager: fake_lsp_manager(enabled: true)
    )
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "<lsp_status", "the override manager must win over the shell reader"
  end

  def test_reader_less_shell_degrades_to_omitted_lsp_section
    shell = Object.new
    shell.define_singleton_method(:config) { {} }
    shell.define_singleton_method(:commands) { {} }
    # An ivar WITHOUT a reader is deliberately invisible to the prompt
    # layer — no reach-ins, ever again.
    shell.instance_variable_set(:@lsp_manager, fake_lsp_manager(enabled: true))

    services = Rubik::Prompt::Services.from_shell(shell)
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    refute_includes prompt, "<lsp_status"
    refute_includes prompt, "<lsp_diagnostics"
  end
end
