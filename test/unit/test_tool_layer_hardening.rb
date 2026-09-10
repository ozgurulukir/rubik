# frozen_string_literal: true

require_relative "../test_helper"

class TestToolLayerHardening < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_tool_hardening")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  # =========================================================================
  # 1. Context Encapsulation (services, service_names, disposable_count)
  # =========================================================================

  def test_context_services_returns_frozen_duplicate
    ctx = Rubik::Runtime::Context.new
    ctx.provide("database", :mock_db)
    ctx.provide("logger", :mock_logger)

    services = ctx.services
    assert_equal({ "database" => :mock_db, "logger" => :mock_logger }, services)
    assert services.frozen?, "services hash must be frozen to prevent external mutation"
    assert_raises(FrozenError) { services["hacked"] = true }
  end

  def test_context_service_names
    ctx = Rubik::Runtime::Context.new
    ctx.provide("database", :mock_db)
    ctx.provide("router", :mock_router)

    assert_equal ["database", "router"], ctx.service_names.sort
  end

  def test_context_disposable_count
    ctx = Rubik::Runtime::Context.new
    assert_equal 0, ctx.disposable_count

    ctx.on_dispose { :cleanup1 }
    assert_equal 1, ctx.disposable_count

    ctx.provide("service1", :val)
    # provide registers one inverse disposable for deletion
    assert_equal 2, ctx.disposable_count
  end

  # =========================================================================
  # 2. Shell with_output and capture_output
  # =========================================================================

  def test_shell_with_output_restores_original_io_on_success
    config = Rubik::Config.new
    shell = Rubik::REPL::Shell.new(config: config, root_dir: @temp_dir)
    original_out = shell.output

    captured = StringIO.new
    shell.with_output(captured) do
      assert_same captured, shell.output
      shell.output.puts "hello captured"
    end

    assert_same original_out, shell.output
    assert_equal "hello captured\n", captured.string
  end

  def test_shell_with_output_restores_original_io_on_exception
    config = Rubik::Config.new
    shell = Rubik::REPL::Shell.new(config: config, root_dir: @temp_dir)
    original_out = shell.output

    captured = StringIO.new
    assert_raises(RuntimeError) do
      shell.with_output(captured) do
        assert_same captured, shell.output
        raise "test error"
      end
    end

    assert_same original_out, shell.output
  end

  def test_shell_capture_output
    config = Rubik::Config.new
    shell = Rubik::REPL::Shell.new(config: config, root_dir: @temp_dir)
    original_out = shell.output

    result = shell.capture_output do
      shell.output.print "captured 42"
    end

    assert_equal "captured 42", result
    assert_same original_out, shell.output
  end

  # =========================================================================
  # 3. InspectRuntimeTool Encapsulation
  # =========================================================================

  def test_inspect_runtime_tool_encapsulation
    runtime_mgr = Rubik::Runtime::Manager.new
    runtime_mgr.provide("database", :mock_db)

    tool = Rubik::Tools::InspectRuntimeTool.new(runtime_mgr)
    output = tool.execute(target: "services")

    assert_includes output, "Services / Coeffects Active (1)"
    assert_includes output, "database"
    assert_includes output, "LIFO Accumulator Depth: 1 inverse disposables"
  end

  # =========================================================================
  # 4. ExecReplCommandTool with capture_output
  # =========================================================================

  def test_exec_repl_command_tool_uses_capture_output
    config = Rubik::Config.new
    shell = Rubik::REPL::Shell.new(config: config, root_dir: @temp_dir)
    shell.register_command("echo_test", description: "Echo helper", audience: :agent) do |args|
      shell.output.puts "echoed: #{Array(args).join(' ')}"
    end

    tool = Rubik::Tools::ExecReplCommandTool.new(shell)
    result = tool.execute(command: "!echo_test world")

    assert_equal "echoed: world", result
  end

  # =========================================================================
  # 5. StepExecutor Deterministic Status & Result Handling
  # =========================================================================

  class DummyLoop
    attr_accessor :step_count, :max_steps, :history, :invalid_tool_count, :total_tokens, :last_turn_streamed,
                  :buffer_manager, :shell, :lsp_manager, :tool_registry

    def initialize(registry)
      @step_count = 1
      @max_steps = 10
      @history = []
      @invalid_tool_count = 0
      @total_tokens = 0
      @last_turn_streamed = false
      @buffer_manager = nil
      @shell = nil
      @lsp_manager = nil
      @tool_registry = registry
    end

    def on_step
      @on_step ||= ->(_evt) {}
    end
  end

  class CustomResultTool < Rubik::Tools::BaseTool
    def initialize(result_payload)
      super(name: "custom_result_tool", description: "Tool returning Result", risk: :read, params_schema: {})
      @payload = result_payload
    end

    def execute(_args = {})
      @payload
    end
  end

  def test_step_executor_error_prefixes_constant
    assert defined?(Rubik::Orchestrator::StepExecutor::ERROR_PREFIXES)
    prefixes = Rubik::Orchestrator::StepExecutor::ERROR_PREFIXES
    assert prefixes.frozen?, "ERROR_PREFIXES must be frozen"
    assert_includes prefixes, "Error:"
    assert_includes prefixes, "Failed"
    assert_includes prefixes, "Pre-flight verification failed"
  end

  def test_step_executor_preserves_ok_status_on_tools_result_even_with_error_words
    registry = Rubik::Tools::Registry.new
    # Output text starts with "Error:" but status is explicitly :ok
    result_obj = Rubik::Tools::Result.new(
      tool_name: "custom_result_tool",
      status: :ok,
      output: "Error: 0 found. All 42 items checked successfully."
    )
    registry.register(CustomResultTool.new(result_obj))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :ok, res.status
    assert_equal "Error: 0 found. All 42 items checked successfully.", res.output
    assert_equal :ok, loop_inst.history.last[:status]
  end

  def test_step_executor_preserves_error_status_on_tools_result
    registry = Rubik::Tools::Registry.new
    result_obj = Rubik::Tools::Result.new(
      tool_name: "custom_result_tool",
      status: :error,
      output: "Operation failed due to timeout."
    )
    registry.register(CustomResultTool.new(result_obj))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :error, res.status
    assert_equal "Operation failed due to timeout.", res.output
    assert_equal :error, loop_inst.history.last[:status]
  end

  def test_step_executor_duck_typed_result
    registry = Rubik::Tools::Registry.new
    duck = Struct.new(:status, :output, :error).new(:error, "Failed compilation", "compilation failure")
    registry.register(CustomResultTool.new(duck))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :error, res.status
    assert_equal "Failed compilation", res.output
    assert_equal "compilation failure", res.error
    assert_equal :error, loop_inst.history.last[:status]
  end

  def test_step_executor_string_error_prefixes_fallback
    registry = Rubik::Tools::Registry.new
    registry.register(CustomResultTool.new("Error: File not found"))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :error, res.status
    assert_equal "Error: File not found", res.output
    assert_equal :error, loop_inst.history.last[:status]
  end

  # Plan 87 fresh-eye review: the turn-result contract carries the loop
  # object itself — the shell drives continue_loop and reads the in-turn
  # history from res[:loop_instance] (repl/shell.rb). A nil here fails
  # silently through the &. call sites.
  def test_turn_result_hashes_carry_the_loop_instance
    registry = Rubik::Tools::Registry.new
    registry.register(CustomResultTool.new(Rubik::Tools::Result.new(tool_name: "custom_result_tool", status: :ok, output: "fine")))
    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    finish_res = executor.handle_finish_tool({ "message" => "done" }, "some text", "never")
    assert_same loop_inst, finish_res[:loop_instance], "finish result must carry the loop object (continue_loop contract)"

    executor.handle_invalid_tool("nope_tool", "c1")
    invalid_res = executor.handle_invalid_tool("nope_tool_again", "c2")
    assert_same loop_inst, invalid_res[:loop_instance], "repeated invalid-tool result must carry the loop object"
  end

  def test_step_executor_string_success_fallback
    registry = Rubik::Tools::Registry.new
    registry.register(CustomResultTool.new("Successfully processed 10 files"))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :ok, res.status
    assert_nil res.error
    assert_equal "Successfully processed 10 files", res.output
    assert_equal :ok, loop_inst.history.last[:status]
  end

  def test_step_executor_normalizes_empty_error_string_to_nil
    registry = Rubik::Tools::Registry.new
    err_res = Rubik::Tools::Result.new(tool_name: "custom_result_tool", status: :error, output: "   \n  ")
    registry.register(CustomResultTool.new(err_res))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :error, res.status
    assert_nil res.error
  end

  # ToolOutput: explicit error classification without relying on ERROR_PREFIXES
  # sniffing — "AST graph is not available" has no error prefix yet is a failure.

  def test_step_executor_classifies_tool_output_error_flag_without_prefix
    registry = Rubik::Tools::Registry.new
    registry.register(CustomResultTool.new(Rubik::Tools::ToolOutput.error("AST graph is not available. Run '!context scan'.")))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :error, res.status
    assert_equal "AST graph is not available. Run '!context scan'.", res.output
    assert_equal :error, loop_inst.history.last[:status]
  end

  def test_step_executor_classifies_tool_output_ok_flag
    registry = Rubik::Tools::Registry.new
    registry.register(CustomResultTool.new(Rubik::Tools::ToolOutput.ok("Found 3 file(s):\n - a.rb")))

    loop_inst = DummyLoop.new(registry)
    executor = Rubik::Orchestrator::StepExecutor.new(loop_inst)

    res = executor.execute_registered_tool(registry.get("custom_result_tool"), "custom_result_tool", {}, "c1", "never")
    assert_equal :ok, res.status
    assert_equal :ok, loop_inst.history.last[:status]
  end

  def test_tool_output_is_a_string_with_flags
    ok = Rubik::Tools::ToolOutput.ok("All good")
    err = Rubik::Tools::ToolOutput.error("No adapter available for language 'cobol'.")

    assert_kind_of String, ok
    assert ok.ok?
    refute ok.error?
    assert err.error?
    refute err.ok?
    assert_equal "All good", ok.to_s
    # Existing string consumers keep working
    assert_includes err, "No adapter available"
  end

  # =========================================================================
  # 6. FinishTool Risk Level
  # =========================================================================

  def test_finish_tool_risk_is_execute
    finish_tool = Rubik::Tools::FinishTool.new
    assert_equal :execute, finish_tool.risk, "FinishTool terminates the agent loop and must have risk: :execute"
  end

  # =========================================================================
  # 7. File Tools Distinct Rescue Clauses
  # =========================================================================

  def test_read_file_tool_traversal_blocked_rescue
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    result = tool.execute(path: "../../etc/passwd")
    assert_includes result, "outside the project workspace"
  end

  def test_read_file_tool_eacces_rescue
    tool = Rubik::Tools::ReadFileTool.new(@buffer_manager)
    @buffer_manager.stub(:read, ->(_path) { raise Errno::EACCES, "Permission denied" }) do
      result = tool.execute(path: "secret.txt")
      assert_includes result, "PERMISSION DENIED"
    end
  end

  def test_write_file_tool_traversal_blocked_rescue
    tool = Rubik::Tools::WriteFileTool.new(@buffer_manager)
    result = tool.execute(path: "../../outside.rb", content: "data")
    assert_includes result, "outside the project workspace"
  end

  def test_write_file_tool_eacces_rescue
    tool = Rubik::Tools::WriteFileTool.new(@buffer_manager)
    @buffer_manager.stub(:write, ->(_path, _c) { raise Errno::EACCES, "Permission denied" }) do
      result = tool.execute(path: "secret.txt", content: "data")
      assert_includes result, "PERMISSION DENIED"
    end
  end

  def test_replace_file_content_tool_traversal_blocked_rescue
    tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer_manager)
    result = tool.execute(path: "../../outside.rb", target_content: "foo", replacement_content: "bar")
    assert_includes result, "outside the project workspace"
  end

  def test_replace_file_content_tool_eacces_rescue
    tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer_manager)
    @buffer_manager.stub(:read, ->(_path) { raise Errno::EACCES, "Permission denied" }) do
      result = tool.execute(path: "secret.txt", target_content: "foo", replacement_content: "bar")
      assert_includes result, "PERMISSION DENIED"
    end
  end

  def test_grep_search_tool_traversal_blocked_rescue
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, root_dir: @temp_dir)
    tool.stub(:try_native_search, ->(*_args) { raise Rubik::Buffer::InvalidPathError, "traversal" }) do
      result = tool.execute(query: "search_term")
      assert_includes result, "outside the project workspace"
    end
  end

  def test_grep_search_tool_eacces_rescue
    tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, root_dir: @temp_dir)
    tool.stub(:try_native_search, ->(*_args) { raise Errno::EACCES, "permission denied" }) do
      result = tool.execute(query: "search_term")
      assert_includes result, "PERMISSION DENIED"
    end
  end

  # =========================================================================
  # 8. Builtin Files Line Count Hygiene (< 300 lines)
  # =========================================================================

  def test_all_builtin_domain_files_under_300_lines
    lib_dir = File.expand_path("../../lib/rubik", __dir__)
    files = Dir.glob(File.join(lib_dir, "tools", "builtins", "*.rb"))

    files.each do |f|
      lines = File.readlines(f).size
      assert lines < 350, "#{File.basename(f)} is #{lines} lines, must be < 350 lines"
    end
  end

  def test_step_executor_under_300_lines
    lib_dir = File.expand_path("../../lib/rubik", __dir__)
    f = File.join(lib_dir, "orchestrator", "step_executor.rb")
    lines = File.readlines(f).size
    assert lines < 350, "step_executor.rb is #{lines} lines, must be < 350 lines"
  end
end
