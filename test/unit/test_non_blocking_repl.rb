# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestNonBlockingREPL < Minitest::Test
  class FakeLLM
    def complete(_history, _opts = {})
      Rubik::LLM::Response.new(text: "Turn completed successfully.")
    end

    def stream_chat(_history, _opts = {}, &block)
      block&.call(Rubik::LLM::Chunk.new(text_delta: "Turn completed successfully."))
      block&.call(Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 3 }, done: true))
      Rubik::LLM::Response.new(text: "Turn completed successfully.")
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_nb_test")
    @temp_home = Dir.mktmpdir("rubik_nb_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
    @shell.instance_variable_set(:@running, true)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_commands_executable_while_subagent_running
    # Spawn a background subagent
    inst = @shell.subagent_supervisor.spawn(role: "Researcher", prompt: "Study concurrency")
    assert inst
    assert_nil @shell.active_loop, "Prompt must be liberated; active_loop should be nil between turns"

    # Execute bang commands without blocking
    @shell.execute_input("!subagents")
    out = @output.string
    assert_includes out, "Researcher"
    assert_includes out, inst.id

    @shell.execute_input("!dmesg")
    assert_includes @output.string, "unit:#{inst.id}"

    @shell.execute_input("!tasks")
    assert_includes @output.string, "No background tasks currently running or tracked."
  end

  def test_statusline_shows_running_units_badge
    # Initial statusline has 0 units running and no badge appended
    line = Rubik::UI::Statusline.render(@shell, @shell.theme)
    refute_includes line, "units running"

    # Spawn subagent
    inst = @shell.subagent_supervisor.spawn(role: "Researcher", prompt: "Study concurrency")
    line = Rubik::UI::Statusline.render(@shell, @shell.theme)
    assert_includes line, "1 units running"

    inst.kill
  end

  def test_free_text_prompt_concurrent_with_subagent
    # Wire a mock LLM provider so free text doesn't attempt real network calls
    llm = FakeLLM.new
    @shell.runtime_manager.provide(:llm_client, llm)
    router = @shell.router
    router.instance_variable_set(:@test_llm, llm)
    def router.route(**)
      { provider: @test_llm, model: "test-model", context_limit: 8192, max_output_tokens: 1024 }
    end

    # Spawn background subagent
    @shell.subagent_supervisor.spawn(role: "Worker", prompt: "Background work")

    # User enters a free text prompt
    @shell.execute_input("Hello, can you do this other task?")
    assert_includes @output.string, "Turn completed successfully."
    assert_nil @shell.active_loop, "Turn must complete and liberate prompt"
  end

  def test_background_subagent_completion_routes_via_terminal_guard_and_injects_xml
    # Subscribe mock reline
    reline_mock = Minitest::Mock.new
    reline_mock.expect(:redisplay, nil)
    @shell.terminal_guard.reline = reline_mock

    # Simulate being inside Reline readline prompt
    @shell.terminal_guard.with_reading do
      @shell.event_bus.emit(
        Rubik::Orchestrator::Subagent::Notices::COMPLETED_EVENT,
        { id: "sub-99", role: "Researcher", state: "completed", max_steps: 20 }
      )
    end

    reline_mock.verify
    assert_includes @output.string, "\r\e[2K"
    assert_includes @output.string, "[Subagent Completed] [sub-99]"

    # Verify XML notification was injected into conversation_history
    last_msg = @shell.conversation_history.last
    refute_nil last_msg
    assert_equal "user", last_msg[:role]
    assert_includes last_msg[:content], "<subagent_notifications>"
    assert_includes last_msg[:content], "sub-99"
  end

  def test_background_task_completion_notifies_terminal_guard
    task = @shell.task_manager.start('ruby -e "exit 0"')
    assert task

    # Wait briefly for thread to complete and sync
    deadline = Time.now + 5
    sleep 0.05 while task.running? && Time.now < deadline

    # Give dispatcher thread a moment to deliver
    @shell.event_bus.drain!

    assert_includes @output.string, "⚡ [Task Done]"
    assert_includes @output.string, task.id
  end
end
