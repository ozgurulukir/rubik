# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/scripted_connect_prompt"
require "rubik/connect"
require "rubik/repl/shell"

class TestReplConnectCommand < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_connect_project")
    @temp_home = Dir.mktmpdir("rubik_connect_home")
    @out = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out)
  end

  def teardown
    begin
      FileUtils.remove_entry(@temp_root)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@temp_home)
    rescue
      nil
    end
  end

  def test_connect_is_registered
    assert @shell.commands.key?("connect"), "expected !connect among registered commands"
    assert_equal "Usage: !connect [--project|--global]", @shell.commands["connect"][:usage]
  end

  def test_connect_non_interactive_reports_honestly
    # StringIO input/output => PromptUI is non-interactive under RUBIK_TEST;
    # the wizard must short-circuit before asking anything, and the handler
    # points at the usage line.
    @shell.execute_input("!connect")

    assert_includes @out.string, "Usage: !connect [--project|--global]"
    assert_nil @config.provider_spec("anything")
  end

  def test_connect_invocation_wires_wizard_and_refreshes_registry
    # Pre-seed a provider, then run !connect with a scripted UI that confirms
    # an ollama connection; after success the registry must expose it.
    @config.set("providers.remote", { "type" => "openai_compatible",
                                      "endpoint" => "https://remote.example.com/v1/chat/completions",
                                      "models" => [{ "name" => "remote-model", "context_limit" => 8192 }] },
                persist: :global)

    # The scripted prompt answers by matcher; build the full flow explicitly
    # through invoke with probe stub to avoid any network touch.
    probe = Class.new do
      def ollama(_host, **_kwargs)
        { ok: true, auth_failed: false, reachable: true, models: ["qwen:7b"] }
      end
    end.new

    ui = ScriptedConnectPrompt.new([
                                     ->(_k, _q, choices, _d) { choices.find { |c| c.include?("Ollama") } },
                                     ->(_k, _q, _c, d) { d },                             # endpoint
                                     ->(_k, _q, choices, _d) { choices.find { |c| c.include?("qwen:7b") } },
                                     ->(_k, _q, choices, _d) { choices.find { |c| c.include?("Sadece default") } },
                                     ->(_k, _q, _c, _d) { true }                          # confirm
                                   ])

    ctx = Rubik::REPL::CommandContext.new(@shell)
    res = Rubik::REPL::Commands::Connect.invoke(ctx, :global, ui: ui, probe: probe)

    assert res[:ok], res.inspect
    # the refresh callback ran through the shell: the new provider is live
    assert @shell.llm_registry.get("ollama").is_a?(Rubik::LLM::OllamaProvider)
    assert_equal "qwen:7b", @config.fetch("models.default")["name"]
  end

  def test_connect_flags_choose_scope
    # --global wins over the wizard's :global default; --project must reach
    # the wizard (its write would be refused for plaintext keys by
    # SecretPolicy — covered in the wizard tests).
    handled = false
    Rubik::REPL::Commands::Connect.singleton_class.class_eval do
      alias_method :original_invoke, :invoke
      define_method(:invoke) do |_ctx, scope, _ui: nil, _probe: nil|
        handled = scope
        { ok: false, reason: :cancelled, notes: [] }
      end
    end

    @shell.execute_input("!connect --global")
    assert_equal :global, handled

    @shell.execute_input("!connect --project")
    assert_equal :project, handled
  ensure
    Rubik::REPL::Commands::Connect.singleton_class.class_eval do
      alias_method :invoke, :original_invoke
      remove_method :original_invoke
    end
  end

  def test_connect_refuses_explicit_session_scope
    # The wizard has no session tier; an explicit --session must be refused
    # honestly instead of being silently coerced into a persistent write.
    @out.reopen
    @shell.execute_input("!connect --session")

    assert_includes @out.string, "Usage: !connect [--project|--global]"
    assert_includes @out.string, "!provider add"
    @out.reopen
    @shell.execute_input("!connect -s")
    assert_includes @out.string, "!provider add"
  end
end
