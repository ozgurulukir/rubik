# frozen_string_literal: true

require_relative "../test_helper"

class TestBufferReminderAndAutoApply < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_project")
    @temp_home = Dir.mktmpdir("rubik_home")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
  end

  def teardown
    remove_temp_dir(@temp_root)
    remove_temp_dir(@temp_home)
  end

  def test_apply_buffer_tool_directly
    tool = Rubik::Tools::ApplyBufferTool.new(@buffer_manager)

    # 1. When clean
    res = tool.execute({})
    assert_includes res, "No unapplied buffer changes"

    # 2. When dirty
    @buffer_manager.write("lib/model_test.rb", "VALUE = 100")
    assert @buffer_manager.dirty?
    refute File.exist?(File.join(@temp_root, "lib/model_test.rb"))

    res2 = tool.execute({})
    assert_includes res2, "Successfully applied 1 modified file(s)"
    refute @buffer_manager.dirty?
    assert File.exist?(File.join(@temp_root, "lib/model_test.rb"))
    assert_equal "VALUE = 100", File.read(File.join(@temp_root, "lib/model_test.rb"))
  end

  def test_prompt_dirty_indicator
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    # Clean buffer prompt
    refute_includes shell.prompt, "DIRTY"

    # Dirty buffer prompt
    @buffer_manager.write("test.rb", "# test")
    assert_includes shell.prompt, "[DIRTY: 1 ✎]"
  end

  def test_turn_based_reminder_in_repl
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)
    @config.set("buffer.reminder_interval", 2)

    # 1. Modify buffer
    @buffer_manager.write("hello.rb", "puts 'hello'")

    # Turn 1
    shell.execute_input("!status")
    refute_includes out.string, "unapplied file modification"

    # Turn 2 (Hits interval 2)
    shell.execute_input("!status")
    assert_includes out.string, "💡 [Rubik::Buffer] 1 unapplied file modification(s) in buffer"
  end

  def test_autoapply_repl_command
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    shell.execute_input("!autoapply on_test")
    assert_includes out.string, "Buffer auto-apply policy set to 'on_test'"
    assert_equal "on_test", @config.fetch("buffer.auto_apply")

    out.reopen
    shell.execute_input("!autoapply status")
    assert_includes out.string, "Mode             : on_test"
  end

  def test_orchestrator_auto_applies_on_finish_when_configured
    @config.set("buffer.auto_apply", "on_finish")
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(
          text: "",
          tool_calls: [
            { "tool" => "write_file", "args" => { "path" => "auto_finish.rb", "content" => "DONE = true" } },
            { "tool" => "finish", "args" => { "message" => "Task completed" } }
          ]
        )
      end
    end.new

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: shell.build_tool_registry,
      shell: shell
    )

    res = loop_orchestrator.run("Write auto_finish.rb and complete")
    assert res[:ok]

    # Verify auto_applied on finish
    refute @buffer_manager.dirty?
    assert File.exist?(File.join(@temp_root, "auto_finish.rb"))
    assert_equal "DONE = true", File.read(File.join(@temp_root, "auto_finish.rb"))
  end

  def test_orchestrator_auto_applies_pre_execution_when_configured
    @config.set("buffer.auto_apply", "on_test")
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      def initialize
        @step = 0
      end

      def complete(_messages, _opts = {})
        @step += 1
        if @step == 1
          Rubik::LLM::Response.new(
            text: "",
            tool_calls: [
              { "tool" => "write_file", "args" => { "path" => "calc.rb", "content" => "class Calc; end" } }
            ]
          )
        elsif @step == 2
          Rubik::LLM::Response.new(
            text: "",
            tool_calls: [
              { "tool" => "run_command", "args" => { "command" => "ls calc.rb" } }
            ]
          )
        else
          Rubik::LLM::Response.new(
            text: "",
            tool_calls: [
              { "tool" => "finish", "args" => { "message" => "Verified on disk" } }
            ]
          )
        end
      end
    end.new

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: shell.build_tool_registry,
      shell: shell
    )

    res = loop_orchestrator.run("Create calc.rb and check file on disk")
    assert res[:ok]
    refute @buffer_manager.dirty?
    assert File.exist?(File.join(@temp_root, "calc.rb"))
  end

  def test_context_builder_includes_buffer_notice_and_auto_apply_attribute
    @buffer_manager.write("dirty_file.rb", "# dirty")
    xml = Rubik::Prompt::ContextBuilder.build_buffer_xml(@buffer_manager, nil, auto_apply: "on_test")

    assert_includes xml, 'dirty="true"'
    assert_includes xml, 'auto_apply="on_test"'
    assert_includes xml, "<notice>"
    assert_includes xml, "apply_buffer"
  end
end
