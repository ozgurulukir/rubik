# frozen_string_literal: true

require_relative "../test_helper"

class TestPlan95SubagentResilienceAndDefensiveIO < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: Dir.pwd)
    @tool_registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      root_dir: Dir.pwd
    )
    @config = Rubik::Config.new
    @supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context,
      buffer_manager: @buffer_manager,
      tool_registry: @tool_registry,
      config: @config
    )
  end

  def teardown
    @supervisor&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
  end

  # =========================================================================
  # 1. Subagent Tool Output Truncation (Phase B)
  # =========================================================================

  def test_dispatch_subagent_tool_truncates_large_output
    giant_output = "A" * 50_000
    mock_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize(out)
        super(name: "giant_tool", description: "returns giant output")
        @out = out
      end

      def execute(_args = {})
        @out
      end
    end.new(giant_output)

    @tool_registry.register(mock_tool)

    inst = @supervisor.spawn(role: "Researcher", prompt: "Run giant tool")
    res = inst.send(:dispatch_subagent_tool, mock_tool, "giant_tool", {})

    assert_operator res.length, :<, 15_000
    assert_includes res, "[Truncated:"
  end

  # =========================================================================
  # 2. Subagent Context Compaction & EmergencyCompactor (Phase A)
  # =========================================================================

  def test_subagent_proactive_context_compaction
    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-test",
      parent_id: "agent-0",
      role: "Compactor Test",
      type_name: "research",
      prompt: "Test compaction",
      context: @root_context,
      tool_registry: @tool_registry,
      context_limit: 1_000,
      config: @config
    )

    # Build a long history exceeding 1000 tokens
    20.times do |i|
      inst.history << { role: "user", content: "Question #{i}: #{'word ' * 50}" }
      inst.history << { role: "assistant", content: "Answer #{i}: #{'detail ' * 50}" }
    end

    initial_size = inst.history.size
    inst.send(:evaluate_subagent_context_compaction!)

    assert_operator inst.history.size, :<, initial_size
    assert(inst.history.any? { |m| m[:content].to_s.include?("omitted") || m[:role] == "user" })
  end

  def test_subagent_emergency_compactor_recovery_on_context_overflow
    call_count = 0
    mock_provider = Object.new
    mock_provider.define_singleton_method(:complete) do |_history, _opts|
      call_count += 1
      raise StandardError, "context_length_exceeded: maximum context length is 32768 tokens, but prompt had 35000" if call_count == 1

      # Second call succeeds
      Struct.new(:text, :tool_calls).new("Recovered successfully after compaction", [])
    end

    inst = Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-overflow",
      parent_id: "agent-0",
      role: "Overflow Recovery",
      type_name: "research",
      prompt: "Handle overflow",
      context: @root_context,
      tool_registry: @tool_registry,
      provider: mock_provider,
      context_limit: 2_000,
      config: @config
    )

    10.times do |i|
      inst.history << { role: "user", content: "Turn #{i}: #{'test ' * 80}" }
      inst.history << { role: "assistant", content: "Response #{i}: #{'reply ' * 80}" }
    end

    res = inst.send(:invoke_provider_with_recovery, {})
    assert_equal 2, call_count
    assert_equal "Recovered successfully after compaction", res.text
  end

  # =========================================================================
  # 3. NativeSearch Line-Level Hard Cap (Phase C)
  # =========================================================================

  def test_native_search_parse_line_truncates_giant_lines
    giant_content = "X" * 10_000
    raw = "lib/foo.rb:42:#{giant_content}"

    parsed = Rubik::Tools::NativeSearch.parse_line(raw)
    refute_nil parsed
    assert_equal "lib/foo.rb", parsed[:file]
    assert_equal 42, parsed[:line]
    assert_operator parsed[:content].length, :<=, 600
    assert_includes parsed[:content], "... [line truncated, 10000 chars total]"
  end

  # =========================================================================
  # 4. GrepSearchTool Output Budget Capping & Line Truncation (Phase C)
  # =========================================================================

  def test_grep_search_tool_line_and_output_budget_capping
    grep_tool = Rubik::Tools::GrepSearchTool.new(root_dir: Dir.pwd)

    # Test sanitize_line_content directly
    giant_line = "Y" * 5_000
    sanitized = grep_tool.send(:sanitize_line_content, giant_line)
    assert_operator sanitized.length, :<=, 600
    assert_includes sanitized, "... [line truncated, 5000 chars total]"

    # Test output budget capping in execute
    mock_matches = 100.times.map do |i|
      { file: "file_#{i}.rb", line: i + 1, content: "Z" * 400 }
    end

    grep_tool.stub(:try_native_search, mock_matches) do
      out = grep_tool.execute(query: "dummy")
      assert_includes out, "... [Grep output capped at 29KB to protect context window."
      assert_operator out.length, :<=, 35_000
    end
  end

  # =========================================================================
  # 5. Scanner Trash & Cache Directory Ignores (Phase D)
  # =========================================================================

  def test_scanner_default_ignores_include_trash_and_caches
    ignores = Rubik::Context::Scanner::DEFAULT_IGNORES
    assert_includes ignores, ".ua/**"
    assert_includes ignores, ".trash*/**"
    assert_includes ignores, "**/.trash*/**"
    assert_includes ignores, ".turbo/**"
    assert_includes ignores, ".sst/**"
    assert_includes ignores, ".next/**"
    assert_includes ignores, ".nuxt/**"

    assert_includes Rubik::Context::Scanner::HARD_PRUNE_ROOTS, ".ua"
    assert_includes Rubik::Context::Scanner::HARD_PRUNE_ROOTS, ".turbo"

    prune_globs = Rubik::Tools::NativeSearch.prune_globs
    assert_includes prune_globs, "!.ua/**"
    assert_includes prune_globs, "!.trash*/**"
  end

  # =========================================================================
  # 6. ManageSubagentsTool Blocking Status Timeout & Guidance (Phase E)
  # =========================================================================

  def test_manage_subagents_status_guidance_when_running
    manage_tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor)

    inst = @supervisor.spawn(role: "Long Task", prompt: "Take your time")
    # Instance is running
    res = manage_tool.execute(action: "status", conversation_id: inst.id)
    data = JSON.parse(res)

    assert_equal "running", data["state"]
    assert_includes data["guidance"], "Subagent is actively working"
    assert_includes data["guidance"], "DO NOT poll 'status' in a loop"
    assert_includes data["guidance"], "Call manage_subagents(action: 'wait', timeout: 30) to block until completion"
  end

  def test_manage_subagents_status_with_blocking_timeout
    manage_tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @supervisor)

    inst = @supervisor.spawn(role: "Fast Task", prompt: "Complete quickly")
    # Complete the instance shortly
    Thread.new do
      sleep 0.05
      inst.instance_variable_set(:@state, :completed)
      inst.instance_variable_set(:@result, "Quick finish")
    end

    res = manage_tool.execute(action: "status", conversation_id: inst.id, timeout: 2)
    data = JSON.parse(res)

    assert_equal "completed", data["state"]
    assert_equal "Quick finish", data["result"]
  end
end
