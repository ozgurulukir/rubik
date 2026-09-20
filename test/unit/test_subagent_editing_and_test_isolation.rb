# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentEditingAndTestIsolation < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("rubik_subagent_editing_test")
    @root_context = Rubik::Runtime::Context.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @tmpdir)
    @tool_registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      root_dir: @tmpdir
    )
    @config = Rubik::Config.new
    @config.set("subagents.auto_apply_buffer", true)
    @supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      buffer_manager: @buffer_manager,
      tool_registry: @tool_registry,
      config: @config,
      root_dir: @tmpdir
    )
  end

  def teardown
    @supervisor&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_coder_archetype_includes_apply_buffer_in_toolset
    inst = @supervisor.spawn(
      type_name: "coder",
      role: "Editor Subagent",
      prompt: "Draft edits"
    )

    reg = inst.tool_registry
    refute_nil reg.get("apply_buffer"), "apply_buffer must be available in coder toolset"
    refute_nil reg.get("write_file"), "write_file must be available in coder toolset"
    refute_nil reg.get("replace_file_content"), "replace_file_content must be available in coder toolset"
    refute_nil reg.get("run_tests"), "run_tests must be available in coder toolset"

    # Research agent still must not have mutating tools
    research_inst = @supervisor.spawn(
      type_name: "research",
      role: "Explorer Subagent",
      prompt: "Find symbols"
    )
    assert_nil research_inst.tool_registry.get("apply_buffer"), "apply_buffer must be excluded from research subagent"
    assert_nil research_inst.tool_registry.get("write_file"), "write_file must be excluded from research subagent"
  end

  def test_subagent_auto_applies_buffer_before_run_tests
    target_file = File.join(@tmpdir, "code.rb")
    File.write(target_file, "def hello; :old; end\n")

    # Mock provider that stages edit then runs tests
    stage = 0
    provider = Object.new
    provider.define_singleton_method(:complete) do |_hist, _opts = {}|
      stage += 1
      if stage == 1
        Struct.new(:content, :tool_calls).new(
          "Updating code",
          [{ "id" => "c1", "tool" => "replace_file_content",
             "args" => { "path" => "code.rb", "start_line" => 1, "target_content" => ":old", "replacement_content" => ":new" } }]
        )
      elsif stage == 2
        Struct.new(:content, :tool_calls).new(
          "Running tests",
          [{ "id" => "c2", "tool" => "run_tests", "args" => { "language" => "ruby" } }]
        )
      else
        Struct.new(:content, :tool_calls).new("All done", [])
      end
    end

    inst = @supervisor.spawn(
      type_name: "coder",
      role: "Testing Subagent",
      prompt: "Fix code and test",
      provider: provider,
      max_steps: 5
    )

    deadline = Time.now + 4
    sleep 0.05 while inst.running? && Time.now < deadline

    # File on disk must reflect the new content because auto_apply_buffer applied before run_tests
    assert_includes File.read(target_file), ":new"
  end

  def test_subagent_auto_applies_buffer_on_completion
    target_file = File.join(@tmpdir, "persist_test.rb")
    File.write(target_file, "original content\n")

    inst = @supervisor.spawn(
      type_name: "coder",
      role: "Finishing Subagent",
      prompt: "Write content and finish",
      workspace: "branch"
    )

    inst.buffer_manager.write(target_file, "updated content from branch\n")
    inst.instance_variable_set(:@state, :completed)

    @supervisor.send(:handle_subagent_completion, inst, nil)

    assert_equal "updated content from branch\n", File.read(target_file)
  end

  def test_base_adapter_targeted_test_cmd_formatting
    adapter = Rubik::Adapter::BaseAdapter.new("ruby", "ruby")

    # Rake test formatting
    cmd = adapter.resolve_test_cmd(@tmpdir, path: "test/unit/test_foo.rb")
    assert_includes cmd, "TEST=test/unit/test_foo.rb"

    # Windows backslash normalisation
    cmd_win = adapter.resolve_test_cmd(@tmpdir, path: "test\\unit\\test_foo.rb")
    assert_includes cmd_win, "TEST=test/unit/test_foo.rb"
    refute_includes cmd_win, "\\"
  end

  def test_run_tests_tool_passes_path_and_timeout_to_adapter
    mock_adapter = Class.new(Rubik::Adapter::BaseAdapter) do
      attr_accessor :received_path, :received_timeout

      def available?
        true
      end

      def run_tests(_root_dir, path: nil, timeout: nil)
        @received_path = path
        @received_timeout = timeout
        { ok: true, output: "Targeted tests passed", duration: 0.1, exit_code: 0 }
      end
    end.new("ruby", "ruby")

    reg = Rubik::Adapter::Registry.new
    reg.register("ruby", mock_adapter)
    tool = Rubik::Tools::RunTestsTool.new(reg)

    output = tool.execute(language: "ruby", path: "test/unit/test_lsp_client.rb", timeout: 45)
    assert_includes output, "PASSED"
    assert_equal "test/unit/test_lsp_client.rb", mock_adapter.received_path
    assert_equal 45, mock_adapter.received_timeout
  end
end
