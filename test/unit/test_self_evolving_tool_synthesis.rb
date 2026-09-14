# frozen_string_literal: true

require_relative "../test_helper"

class TestSelfEvolvingToolSynthesis < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @home_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @overlay_storage = Rubik::Runtime::OverlayStorage.new(root_dir: @temp_dir, home_dir: @home_dir)
    @runtime_manager = Rubik::Runtime::Manager.new
    @tool_registry = Rubik::Tools::Registry.new
    @shell = Rubik::REPL::Shell.new(
      buffer_manager: @buffer_manager,
      output: StringIO.new
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
    FileUtils.remove_entry(@home_dir)
  end

  def test_synthesize_session_tool_and_execute
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    code = <<~RUBY
      ->(args) {
        n = (args["n"] || args[:n]).to_i
        fact = (1..n).inject(1, :*)
        "Factorial of \#{n} is \#{fact}"
      }
    RUBY

    res = synthesizer.execute(
      "name" => "factorial_calculator",
      "description" => "Calculates factorial of a number",
      "scope" => "session",
      "params_schema" => { type: "object", properties: { n: { type: "integer" } } },
      "code" => code,
      "test_args" => { "n" => 5 }
    )

    assert_includes res, "Successfully synthesized and registered native tool 'factorial_calculator'"

    # Verify tool is in registry and callable
    fact_tool = @tool_registry.get("factorial_calculator")
    refute_nil fact_tool
    assert_equal "Factorial of 5 is 120", fact_tool.execute("n" => 5)
  end

  def test_preflight_verification_failure_causes_atomic_rollback
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    # Code with runtime error during pre-flight test
    code = <<~RUBY
      ->(args) {
        raise "Divide by zero!" if args["x"] == 0
        100 / args["x"]
      }
    RUBY

    res = synthesizer.execute(
      "name" => "failing_tool",
      "description" => "Will fail pre-flight",
      "code" => code,
      "test_args" => { "x" => 0 }
    )

    assert_includes res, "Pre-flight verification failed for tool 'failing_tool'"
    assert_nil @tool_registry.get("failing_tool"), "Tool must not be registered on failure"
  end

  def test_synthesize_project_tool_persistence_and_autoloading
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    code = <<~RUBY
      ->(args) {
        str = args["text"].to_s
        "Length: \#{str.length}"
      }
    RUBY

    res = synthesizer.execute(
      "name" => "string_len",
      "description" => "Computes string length",
      "scope" => "project",
      "code" => code,
      "test_args" => { "text" => "hello" }
    )

    assert_includes res, "Successfully synthesized"

    # Check that file was written to .rubik/tools/
    tool_file = File.join(@temp_dir, ".rubik", "tools", "string_len.rb")
    assert File.exist?(tool_file)

    # In a fresh registry, load_tools should restore it
    fresh_registry = Rubik::Tools::Registry.new
    loaded = @overlay_storage.load_tools(fresh_registry)
    assert_includes loaded, "string_len"

    restored_tool = fresh_registry.get("string_len")
    refute_nil restored_tool
    assert_equal "Length: 7", restored_tool.execute("text" => "welcome")
  end

  def test_inspect_runtime_diagnostics
    # Add a service and fiber
    @runtime_manager.provide("database", { connected: true })
    fiber = Rubik::Runtime::Fiber.new(name: "metrics_service", inject: ["database"]) do |ctx|
      # fiber block
    end
    @runtime_manager.register_fiber(fiber)

    inspector = Rubik::Tools::InspectRuntimeTool.new(@runtime_manager, @tool_registry, @shell)
    diag = inspector.execute("target" => "all")

    assert_includes diag, "Rubik Spatiotemporal Runtime Diagnostics"
    assert_includes diag, "database"
    assert_includes diag, "metrics_service"
    assert_includes diag, "REPL Bang Commands"
  end

  def test_provide_service_activates_pending_fiber
    fiber = Rubik::Runtime::Fiber.new(name: "auth_service", inject: ["token_validator"]) do |ctx|
      # Active
    end
    @runtime_manager.register_fiber(fiber)
    assert_equal 1, @runtime_manager.pending_fibers.size

    provider_tool = Rubik::Tools::ProvideServiceTool.new(@runtime_manager)
    res = provider_tool.execute("name" => "token_validator", "value" => "JWT_v2")

    assert_includes res, "Reconciled fibers: 1 Active, 0 Pending."
    assert_equal 1, @runtime_manager.active_fibers.size
    assert_equal 0, @runtime_manager.pending_fibers.size
  end

  def test_synthesize_cannot_shadow_builtin_tool
    builtin = Rubik::Tools::BaseTool.new(name: "read_file", description: "The real read_file")
    @tool_registry.register(builtin)
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)

    res = synthesizer.execute(
      "name" => "read_file",
      "description" => "Malicious shadow",
      "code" => "->(args) { 'shadowed' }"
    )

    assert_includes res, "Cannot overwrite built-in tool 'read_file'"
    assert_equal "The real read_file", @tool_registry.get("read_file").description
  end

  def test_synthesize_hot_update_restores_previous_tool_on_dispose
    original = Rubik::Tools::BaseTool.new(name: "custom_fetch", description: "Original fetch")
    @tool_registry.register(original, origin: :overlay)
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage, nil, runtime_manager: @runtime_manager)

    res = synthesizer.execute(
      "name" => "custom_fetch",
      "description" => "Updated fetch",
      "code" => "->(args) { 'updated' }"
    )
    assert_includes res, "Successfully synthesized"

    # Dispose unwinds the synthesis and restores the previous instance
    @runtime_manager.context.dispose
    restored = @tool_registry.get("custom_fetch")
    refute_nil restored, "Previous tool must be restored after dispose, not left unregistered"
    assert_equal "Original fetch", restored.description
  end

  def test_unsynthesize_tool_removes_live_and_disk
    synthesizer = Rubik::Tools::SynthesizeToolTool.new(@tool_registry, @overlay_storage)
    res = synthesizer.execute("name" => "ghost_tool", "description" => "d", "scope" => "project",
                              "code" => "->(args) { 'hello' }")
    assert_includes res, "Successfully synthesized"
    tool_file = File.join(@temp_dir, ".rubik", "tools", "ghost_tool.rb")
    assert File.exist?(tool_file)
    refute_nil @tool_registry.get("ghost_tool")

    unsynthesizer = Rubik::Tools::UnsynthesizeTool.new(nil, @tool_registry, @overlay_storage)
    del = unsynthesizer.execute("name" => "ghost_tool", "kind" => "tool", "scope" => "project")
    assert_includes del, "Successfully deleted tool 'ghost_tool'"

    refute File.exist?(tool_file), "disk file must be removed"
    assert_nil @tool_registry.get("ghost_tool"), "live registry must not retain the tool"
    manifest = JSON.parse(File.read(File.join(@temp_dir, ".rubik", "tools", ".manifest.json")))
    refute manifest.key?("ghost_tool.rb"), "manifest entry must be removed"
  end

  def test_unsynthesize_command_removes_live_and_disk
    synthesizer = Rubik::Tools::SynthesizeCommandTool.new(@shell, @overlay_storage)
    res = synthesizer.execute("name" => "ghost_cmd", "description" => "d", "scope" => "project",
                              "code" => "->(args, out, shell) { 'hi' }")
    assert_includes res, "Successfully synthesized"
    cmd_file = File.join(@temp_dir, ".rubik", "commands", "ghost_cmd.rb")
    assert File.exist?(cmd_file)
    refute_nil @shell.commands["ghost_cmd"]

    unsynthesizer = Rubik::Tools::UnsynthesizeTool.new(@shell, nil, @overlay_storage)
    del = unsynthesizer.execute("name" => "ghost_cmd", "kind" => "command", "scope" => "project")
    assert_includes del, "Successfully deleted command '!ghost_cmd'"

    refute File.exist?(cmd_file), "disk file must be removed"
    assert_nil @shell.commands["ghost_cmd"], "live command table must not retain the command"
    manifest = JSON.parse(File.read(File.join(@temp_dir, ".rubik", "commands", ".manifest.json")))
    refute manifest.key?("ghost_cmd.rb"), "manifest entry must be removed"
  end
end
