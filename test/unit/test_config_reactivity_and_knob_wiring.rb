# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/repl/shell"

class TestConfigReactivityAndKnobWiring < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if File.directory?(@temp_home)
  end

  # Scenario 1: Config#on_change prefix filtering and callback invocation with (key, new_val, old_val)
  def test_on_change_listener_registration_and_prefix_matching
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    sandbox_events = []
    tools_events = []
    global_events = []

    config.on_change("sandbox") { |key, val, old| sandbox_events << [key, val, old] }
    config.on_change("tools") { |key, val, old| tools_events << [key, val, old] }
    config.on_change { |key, val, old| global_events << [key, val, old] }

    config.set("sandbox.driver", "process")
    config.set("tools.timeout_seconds", 45)
    config.set("ui.theme", "dark")

    assert_equal 1, sandbox_events.size
    assert_equal "sandbox.driver", sandbox_events.first[0]
    assert_equal "process", sandbox_events.first[1]

    assert_equal 1, tools_events.size
    assert_equal "tools.timeout_seconds", tools_events.first[0]
    assert_equal 45, tools_events.first[1]
    assert_equal 30, tools_events.first[2]

    assert_equal 3, global_events.size
  end

  # Scenario 2: Config#on_change disposal inverse proc execution
  def test_on_change_cleanup_inverse_proc
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    call_count = 0

    cleanup = config.on_change("sandbox") do
      call_count += 1
    end

    config.set("sandbox.allow_network", true)
    assert_equal 1, call_count

    # Execute inverse cleanup
    cleanup.call

    config.set("sandbox.allow_network", false)
    assert_equal 1, call_count, "Listener should not be invoked after cleanup"
  end

  # Scenario 3: Config#set emits :config_changed on EventBus
  def test_config_set_emits_event_bus_notification
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    event_bus = Rubik::EventBus.new
    config.event_bus = event_bus

    emitted = []
    event_bus.subscribe(:config_changed) do |payload|
      emitted << payload
    end

    config.set("tools.timeout_seconds", 60)

    assert_equal 1, emitted.size
    payload = emitted.first
    assert_equal "tools.timeout_seconds", payload[:key]
    assert_equal 60, payload[:value]
    assert_equal 30, payload[:old_val]

    # Setting identical value should not re-emit
    config.set("tools.timeout_seconds", 60)
    assert_equal 1, emitted.size
  end

  # Scenario 4: set_model_spec triggers change notifications
  def test_set_model_spec_notifies_changes
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)

    models_events = []
    model_events = []
    config.on_change("models") { |k, v, o| models_events << [k, v, o] }
    config.on_change("model") { |k, v, o| model_events << [k, v, o] }

    config.set_model_spec(:default, provider: "anthropic", name: "claude-3-5-sonnet")
    assert_equal 1, models_events.size
    assert_equal "models.default", models_events.first[0]
    assert_equal "anthropic", models_events.first[1]["provider"]

    assert_equal 1, model_events.size
    assert_equal "model", model_events.first[0]
    assert_equal "anthropic", model_events.first[1]["provider"]

    # Non-default role should only notify models.<role>
    config.set_model_spec(:fast, provider: "openai", name: "gpt-4o-mini")
    assert_equal 2, models_events.size
    assert_equal "models.fast", models_events.last[0]
    assert_equal 1, model_events.size, "model.* should not be notified for non-default role"
  end

  # Scenario 5: Scanner custom includes and custom excludes filtering
  def test_scanner_custom_includes_and_excludes_filtering
    File.write(File.join(@temp_dir, "app.rb"), "puts 'app'")
    File.write(File.join(@temp_dir, "util.rb"), "puts 'util'")
    File.write(File.join(@temp_dir, "notes.txt"), "some notes")
    FileUtils.mkdir_p(File.join(@temp_dir, "test"))
    File.write(File.join(@temp_dir, "test", "test_app.rb"), "puts 'test'")

    # Without custom includes: all non-ignored files are scanned
    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, native: false)
    files = scanner.scan
    assert files.key?("app.rb")
    assert files.key?("notes.txt")
    assert files.key?("test/test_app.rb")

    # With custom includes: only *.rb files
    rb_scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir, includes: ["*.rb"], native: false)
    rb_files = rb_scanner.scan
    assert rb_files.key?("app.rb")
    assert rb_files.key?("util.rb")
    assert rb_files.key?("test/test_app.rb")
    refute rb_files.key?("notes.txt")

    # With custom includes AND excludes
    filtered_scanner = Rubik::Context::Scanner.new(
      root_dir: @temp_dir,
      includes: ["*.rb"],
      excludes: ["test/**"],
      native: false
    )
    filtered_files = filtered_scanner.scan
    assert filtered_files.key?("app.rb")
    assert filtered_files.key?("util.rb")
    refute filtered_files.key?("test/test_app.rb")
    refute filtered_files.key?("notes.txt")
  end

  # Scenario 6: Index filter update (update_file_filters) and full scan triggering
  def test_context_index_update_file_filters
    File.write(File.join(@temp_dir, "server.rb"), "server")
    File.write(File.join(@temp_dir, "style.css"), "css")

    index = Rubik::Context::Index.new(root_dir: @temp_dir, native: false)
    index.full_scan
    assert index.files.key?("server.rb")
    assert index.files.key?("style.css")

    # Update file filters live
    index.update_file_filters(includes: ["*.rb"])
    assert index.files.key?("server.rb")
    refute index.files.key?("style.css")
  end

  # Scenario 7: Composition.build wires context.include/context.exclude and event_bus
  def test_composition_build_wires_context_filters_and_event_bus
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("context.include", ["*.rb", "*.py"])
    config.set("context.exclude", ["vendor/**", "build/**"])
    event_bus = Rubik::EventBus.new

    parts = Rubik::REPL::Composition.build(
      config: config,
      event_bus: event_bus,
      root_dir: @temp_dir
    )

    assert_equal ["*.rb", "*.py"], parts.context_index.scanner.custom_includes
    assert_equal ["vendor/**", "build/**"], parts.context_index.scanner.custom_excludes
    assert_same event_bus, config.event_bus
  end

  # Scenario 8: RunCommandTool dynamic timeout from tools.timeout_seconds
  def test_run_command_tool_dynamic_timeout
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config)
    guard = Rubik::Security::Guard.new
    tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: @temp_dir)

    captured_timeout = nil
    runner.define_singleton_method(:run) do |_cmd, opts = {}|
      captured_timeout = opts[:timeout]
      { ok: true, output: "done", exit_code: 0 }
    end

    # Default timeout is 30 seconds
    tool.execute("command" => "echo test")
    assert_equal 30, captured_timeout

    # Dynamic knob change via config
    config.set("tools.timeout_seconds", 90)
    tool.execute("command" => "echo test")
    assert_equal 90, captured_timeout

    # Explicit argument overrides config knob
    tool.execute("command" => "echo test", "timeout" => 15)
    assert_equal 15, captured_timeout
  end

  # Scenario 9: StreamManager respects capture_reasoning knob
  def test_stream_manager_respects_capture_reasoning_knob
    mock_loop = Object.new
    reasoning_enabled = true
    step_events = []

    mock_loop.define_singleton_method(:safe_config) do |key, default|
      key == "llm.capture_reasoning" ? reasoning_enabled : default
    end
    mock_loop.define_singleton_method(:on_step) do
      ->(info) { step_events << info }
    end
    mock_loop.define_singleton_method(:step_count) { 1 }
    mock_loop.define_singleton_method(:max_steps) { 10 }
    mock_loop.define_singleton_method(:last_turn_streamed=) { |_| }
    mock_loop.define_singleton_method(:history) { [] }

    chunk = Struct.new(:reasoning_delta, :text_delta).new("thinking process...", "answer")
    chunk.define_singleton_method(:reasoning_delta?) { true }
    chunk.define_singleton_method(:text_delta?) { true }

    mock_provider = Object.new
    mock_provider.define_singleton_method(:stream_chat) do |_hist, _opts, &block|
      block.call(chunk)
    end
    mock_loop.define_singleton_method(:provider) { mock_provider }

    stream_mgr = Rubik::Orchestrator::StreamManager.new(mock_loop)
    stream_mgr.define_singleton_method(:build_response_from_chunks) do |_chunks, **_opts|
      Rubik::LLM::Response.new(text: "answer")
    end

    # 1. Reasoning enabled
    reasoning_enabled = true
    step_events.clear
    stream_mgr.execute_streaming_request({})
    assert step_events.any? { |e| e[:type] == :llm_thought_delta }, "Thought delta should be emitted when capture_reasoning is true"

    # 2. Reasoning disabled
    reasoning_enabled = false
    step_events.clear
    stream_mgr.execute_streaming_request({})
    refute step_events.any? { |e| e[:type] == :llm_thought_delta }, "Thought delta must NOT be emitted when capture_reasoning is false"
  end

  # Scenario 10: ApplyBufferTool execution prevention when buffer.model_can_apply: false
  def test_apply_buffer_tool_respects_model_can_apply_knob
    buffer_mgr = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    buffer_mgr.write("file.txt", "content")
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    mock_shell = Object.new
    mock_shell.define_singleton_method(:config) { config }
    mock_shell.define_singleton_method(:sync_context_and_ast) { |_files| }

    tool = Rubik::Tools::ApplyBufferTool.new(buffer_mgr, mock_shell)

    # By default buffer.model_can_apply is true -> application succeeds
    res = tool.execute
    assert_includes res, "Successfully applied"
    assert_equal "content", File.read(File.join(@temp_dir, "file.txt"))

    # When buffer.model_can_apply is false -> model write is rejected
    buffer_mgr.write("file.txt", "modified content")
    config.set("buffer.model_can_apply", false)

    res2 = tool.execute
    assert_includes res2, "disabled by configuration (buffer.model_can_apply: false)"
    assert_equal "content", File.read(File.join(@temp_dir, "file.txt")), "File on disk must not change when disabled"
  end

  # Scenario 11: Sandbox::Runner live reconfiguration on sandbox.* change (reconfigure!)
  def test_sandbox_runner_reconfigures_on_sandbox_config_change
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir, config: config)

    refute runner.allow_network?
    refute runner.sandbox_enabled?

    # Dynamically change sandbox setting
    config.set("sandbox.allow_network", true)
    assert runner.allow_network?, "Runner should reactively update allow_network"

    config.set("sandbox.enabled", true)
    assert runner.sandbox_enabled?, "Runner should reactively update sandbox_enabled"

    mock_driver_class = Class.new(Rubik::Sandbox::Driver::Base) do
      def name
        "testbox"
      end

      def available?
        true
      end
    end
    Rubik::Sandbox::Driver.register("testbox", mock_driver_class)

    config.set("sandbox.driver", "testbox")
    assert_equal "testbox", runner.driver.name
  ensure
    Rubik::Sandbox::Driver.unregister("testbox")
  end

  # Scenario 12: Repair::Loop attempts budget from repair.max_attempts config
  def test_repair_loop_uses_config_max_attempts
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    config.set("repair.max_attempts", 7)

    loop_with_config = Rubik::Repair::Loop.new(
      provider: Object.new,
      buffer_manager: Object.new,
      snapshot_store: Object.new,
      adapter_registry: Object.new,
      config: config
    )
    assert_equal 7, loop_with_config.max_attempts

    # Explicit max_attempts overrides config
    loop_with_override = Rubik::Repair::Loop.new(
      provider: Object.new,
      buffer_manager: Object.new,
      snapshot_store: Object.new,
      adapter_registry: Object.new,
      max_attempts: 2,
      config: config
    )
    assert_equal 2, loop_with_override.max_attempts
  end

  # Scenario 13: Shell#stop respects buffer.exit_guard and cleans up listeners
  def test_shell_stop_respects_buffer_exit_guard_and_cleans_up_listeners
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell_out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: config, output: shell_out, root_dir: @temp_dir)

    shell.buffer_manager.write("dirty.txt", "unsaved data")
    assert shell.buffer_manager.dirty?

    # By default buffer.exit_guard is true -> warning printed on stop
    shell.stop
    assert_includes shell_out.string, "Warning: You have 1 unapplied dirty buffer change(s)"
    assert_empty shell.config_cleanups

    # When exit_guard is false -> warning is suppressed
    shell_out2 = StringIO.new
    shell2 = Rubik::REPL::Shell.new(config: config, output: shell_out2, root_dir: @temp_dir)
    config.set("buffer.exit_guard", false)
    shell2.buffer_manager.write("dirty2.txt", "unsaved data")

    shell2.stop
    refute_includes shell_out2.string, "Warning: You have"
    assert_empty shell2.config_cleanups
  end

  # Scenario 14: ConfigWiring reactive updates without ad-hoc ladder in workspace.rb
  def test_config_wiring_reactive_updates_via_config_set
    config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(config: config, root_dir: @temp_dir)

    extra_dir = Dir.mktmpdir
    begin
      # 1. Workspace additional roots
      shell.config.set("workspace.additional_roots", [extra_dir])
      assert_includes shell.buffer_manager.additional_roots, File.expand_path(extra_dir)

      # 2. Workspace external writes
      shell.config.set("workspace.allow_external_writes", true)
      assert_equal true, shell.buffer_manager.allow_external_writes

      # 3. LSP stop all
      stopped = false
      shell.lsp_manager.define_singleton_method(:stop_all) { stopped = true }
      shell.config.set("lsp.enabled", false)
      assert stopped, "lsp.enabled: false should invoke stop_all"

      # 4. LLM registry reload and route stamp reset
      shell.conversation_route_stamp = { model: "test" }
      shell.config.set("llm.default_max_output_tokens", 8192)
      assert_nil shell.conversation_route_stamp, "Sticky route stamp should be cleared on llm config change"
    ensure
      shell.stop
      FileUtils.remove_entry(extra_dir) if File.directory?(extra_dir)
    end
  end
end
