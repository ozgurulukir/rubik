# frozen_string_literal: true

require_relative "../test_helper"

# Behavior lock for the per-dispatch CommandContext (§7.1 ShellDeps pattern
# on the command axis): capture-correct dynamic out, ServiceCatalog-derived
# readers, write-through rebindable state, and a closed surface.
class TestCommandContext < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @temp_home = Dir.mktmpdir
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(
      config: @config,
      buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_dir),
      output: @output
    )
  end

  def teardown
    @shell.stop
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@temp_home)
  end

  def ctx
    Rubik::REPL::CommandContext.new(@shell)
  end

  def test_out_tracks_the_active_output_swap
    context = ctx
    assert_same @output, context.out

    swapped = StringIO.new
    @shell.with_output(swapped) do
      assert_same swapped, context.out
    end
    assert_same @output, context.out
  end

  def test_output_alias_matches_out_for_ui_duck
    context = ctx
    assert_same context.out, context.output
  end

  def test_io_conveniences_print_to_the_active_output
    context = ctx
    context.puts "hello"
    context.print "world"
    assert_includes @output.string, "hello"
    assert_includes @output.string, "world"
  end

  def test_service_readers_resolve_to_the_shell_instances
    context = ctx
    assert_same @shell.config, context.config
    assert_same @shell.buffer_manager, context.buffer_manager
    assert_same @shell.recorder, context.recorder
    assert_same @shell.llm_registry, context.llm_registry
    assert_same @shell.commands, context.commands
  end

  def test_rebindable_state_writes_through_to_the_shell
    context = ctx

    history = [{ "role" => "user", "content" => "hi" }]
    context.conversation_history = history
    assert_same history, @shell.conversation_history

    context.conversation_history << { "role" => "assistant", "content" => "ho" }
    assert_equal 2, @shell.conversation_history.size

    sentinel = Object.new
    context.active_loop = sentinel
    assert_same sentinel, @shell.active_loop
  ensure
    @shell.active_loop = nil
  end

  def test_request_paste_sets_the_shell_flag
    refute @shell.instance_variable_get(:@paste_requested)
    ctx.request_paste!
    assert @shell.instance_variable_get(:@paste_requested)
  ensure
    @shell.instance_variable_set(:@paste_requested, false)
  end

  def test_session_replayer_wraps_the_real_shell
    replayer = ctx.session_replayer
    assert_instance_of Rubik::Session::Replayer, replayer
    # The replayer plants @replaying on its receiver, so it must hold the
    # real Shell — not the ctx.
    assert_same @shell, replayer.shell
  end

  def test_surface_is_closed
    context = ctx
    refute_respond_to context, :register_command
    refute_respond_to context, :unregister_command
    refute_respond_to context, :execute_input
    refute_respond_to context, :execute_command
    refute_respond_to context, :hooks
    refute_respond_to context, :tool_registry
    refute_respond_to context, :ui_renderer
  end

  def test_effect_and_reader_surface_is_frozen
    expected = [
      "out", "output", "puts", "print", "flush",
      "indexer_thread", "input", "commands",
      "config", "event_bus", "guard", "buffer_manager", "snapshot_store", "cache_store", "ast_graph",
      "context_index", "recorder", "adapter_registry", "llm_registry", "router", "runtime_manager",
      "overlay_storage", "lsp_manager", "mcp_manager", "skill_manager", "sandbox_runner",
      "task_manager", "subagent_supervisor",
      "plugin_manager", "plugin_storage",
      "theme",
      "conversation_history", "conversation_history=", "active_loop", "active_loop=",
      "conversation_route_stamp=", "agent_caller", "current_model_spec",
      "stop", "execute_free_text", "resume_session", "refresh_ui!", "render_step_event",
      "detect_git_branch", "sync_context_and_ast", "sync_workspace_index!",
      "resync_llm_route!", "trim_conversation_window!", "ask_yes_no", "orchestrator_loop",
      "warm_ast_graph", "build_tool_registry", "request_paste!", "session_replayer"
    ].sort
    assert_equal expected, Rubik::REPL::CommandContext.instance_methods(false).sort.map(&:to_s)
  end
end
