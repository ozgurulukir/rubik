# frozen_string_literal: true

require_relative "../test_helper"

class TestPluginReplIntegration < Minitest::Test
  def setup
    @config = Rubik::Config.new
    @config.set("plugins.aliases", { "p" => "plugins" })

    @shell = Rubik::REPL::Shell.new(config: @config, output: StringIO.new, input: StringIO.new)
  end

  def teardown
    @shell.stop
  end

  def test_shell_initializes_plugin_manager
    manager = @shell.runtime_manager.context.get(:plugin_manager)
    assert manager
    assert_instance_of Rubik::Plugin::Manager, manager
  end

  def test_plugins_command_exists
    assert @shell.commands.key?("plugins")

    # We set an alias p -> plugins in config, so it should resolve correctly
    parsed = Rubik::REPL::CommandParser.parse("!p")
    # Execute the command, which should resolve the alias internally
    @shell.execute_command(parsed)

    # Should print to shell output
    assert_includes @shell.output.string, "Eklentiler (Plugins)"
  end

  def test_plugins_command_displays_active_plugin_state
    $:.unshift File.expand_path("../fixtures/plugins/rubik-plugin-example/lib", __dir__)
    config = Rubik::Config.new
    config.set("plugins.load", ["rubik-plugin-example"])
    config.set("plugins.aliases", { "pl" => "!plugins" })

    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: out, input: StringIO.new)

    parsed = Rubik::REPL::CommandParser.parse("!pl")
    shell.execute_command(parsed)

    assert_includes out.string, "rubik-plugin-example [active]"
    assert_includes out.string, "!pl -> !plugins"
    shell.stop
  end

  def test_shell_tolerates_non_hash_plugins_aliases_config
    config = Rubik::Config.new
    config.set("plugins.aliases", "invalid_string_not_a_hash")

    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: out, input: StringIO.new)
    assert shell
    shell.stop
  end
end
