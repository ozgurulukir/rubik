# frozen_string_literal: true

require_relative "../test_helper"

class TestOrchestratorLoop < Minitest::Test
  class MockProvider < Rubik::LLM::BaseProvider
    attr_accessor :responses, :stream_chat_called, :complete_called, :last_messages, :last_opts

    def initialize(responses = [])
      super()
      @responses = responses.dup
      @stream_chat_called = false
      @complete_called = false
      @last_messages = nil
      @last_opts = nil
    end

    def complete(messages, opts = {})
      @complete_called = true
      @last_messages = messages
      @last_opts = opts
      res = @responses.shift
      return res if res.is_a?(Rubik::LLM::Response)

      text = res || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text)
    end
  end

  class StreamingMockProvider < MockProvider
    def stream_chat(messages, opts = {}, &block)
      @stream_chat_called = true
      @last_messages = messages
      @last_opts = opts
      res = @responses.shift
      res = Rubik::LLM::Response.new(text: res) if res.is_a?(String)
      res ||= Rubik::LLM::Response.new(text: '{"tool": "finish", "args": { "message": "streamed done" }}')

      block.call(Rubik::LLM::Chunk.new(text_delta: res.text, done: true)) if block_given?
      res
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_loop_test")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new
    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)

    @events = []
    @on_step = ->(event) { @events << event }
    @provider = MockProvider.new
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def create_loop(provider: @provider, max_steps: 10, warn_at_ratio: 0.75, context_limit: 16_000, max_output_tokens: 2_000, shell: nil)
    Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @registry,
      max_steps: max_steps,
      warn_at_ratio: warn_at_ratio,
      on_step: @on_step,
      context_limit: context_limit,
      max_output_tokens: max_output_tokens,
      shell: shell
    )
  end

  # --- Initialization & Accessors ---

  def test_initialize_defaults_and_collaborators
    loop_inst = create_loop
    assert_equal 10, loop_inst.max_steps
    assert_equal 0.75, loop_inst.warn_at_ratio
    assert_equal 16_000, loop_inst.context_limit
    assert_equal 2_000, loop_inst.max_output_tokens
    assert_equal 0, loop_inst.step_count
    assert_equal [], loop_inst.history
    assert_equal({ input: 0, output: 0 }, loop_inst.total_tokens)
    refute loop_inst.last_turn_streamed
    assert_equal 0, loop_inst.empty_response_count

    assert_instance_of Rubik::Orchestrator::ActivityLog, loop_inst.activity
    assert_instance_of Rubik::Orchestrator::StepExecutor, loop_inst.step_executor
    assert_instance_of Rubik::Orchestrator::BudgetManager, loop_inst.budget_manager
    assert_instance_of Rubik::Orchestrator::StreamManager, loop_inst.stream_manager
  end

  def test_initialize_with_shell_pulls_collaborator_state
    mock_shell = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager, :commands).new(
      @buffer_manager,
      nil,
      nil,
      nil,
      { "llm.stream" => false },
      nil,
      nil
    )

    loop_inst = create_loop(shell: mock_shell)
    assert_equal @buffer_manager, loop_inst.buffer_manager
    assert_equal({ "llm.stream" => false }, loop_inst.config)
  end

  # --- Budget Extension & Continuation ---

  def test_extend_budget
    loop_inst = create_loop(max_steps: 10)
    loop_inst.extend_budget(5)
    assert_equal 15, loop_inst.max_steps
  end

  def test_continue_loop_appends_continuation_message_and_executes
    @provider.responses = ['{"tool": "finish", "args": { "message": "continued task completed" }}']
    loop_inst = create_loop(max_steps: 5)
    loop_inst.instance_variable_set(:@step_count, 3)

    res = loop_inst.continue_loop(10)
    assert res[:ok]
    assert_equal 15, loop_inst.max_steps
    user_msg = loop_inst.history.find { |m| m[:role] == "user" && m[:content].include?("step_budget_extended") }
    refute_nil user_msg
    assert_includes user_msg[:content], 'extra="10"'
  end

  # --- Run & Lifecycle ---

  def test_run_initializes_history_and_executes_loop
    @provider.responses = ['{"tool": "finish", "args": { "message": "finished" }}']
    loop_inst = create_loop

    res = loop_inst.run("Test task prompt")
    assert res[:ok]
    assert_equal "finished", res[:output]

    # Check history structure
    assert_equal "system", loop_inst.history.first[:role]
    user_task_msg = loop_inst.history.find { |m| m[:role] == "user" }
    refute_nil user_task_msg
    assert_includes user_task_msg[:content], "Test task prompt"
  end

  def test_run_injects_conversation_history
    @provider.responses = ['{"tool": "finish", "args": { "message": "done with history" }}']
    loop_inst = create_loop

    prior_history = [
      { role: "user", content: "Previous question" },
      { role: "assistant", content: "Previous answer" },
      { role: nil, content: "Ignored invalid role" }
    ]

    loop_inst.run("Follow up task", conversation_history: prior_history)

    roles = loop_inst.history.map { |m| m[:role] }
    contents = loop_inst.history.map { |m| m[:content] }

    assert_includes roles, "user"
    assert_includes roles, "assistant"
    assert_includes contents, "Previous question"
    assert_includes contents, "Previous answer"
  end

  def test_run_disposes_loop_context
    rt_ctx = Rubik::Runtime::Context.new
    runtime_manager = Struct.new(:context).new(rt_ctx)
    mock_shell = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager, :commands).new(
      @buffer_manager, nil, nil, nil, {}, runtime_manager, nil
    )

    @provider.responses = ['{"tool": "finish", "args": { "message": "context tested" }}']
    loop_inst = create_loop(shell: mock_shell)

    res = loop_inst.run("Task needing context")
    assert res[:ok]
    # @loop_context is disposed in the ensure block
    assert loop_inst.loop_context.disposed?
  end

  # --- LLM Request Routing (Batch vs Stream) ---

  def test_send_llm_request_uses_batch_when_provider_lacks_stream_chat
    @provider.responses = ['{"tool": "finish", "args": { "message": "batch finish" }}']
    loop_inst = create_loop(provider: @provider)

    res = loop_inst.run("Batch test")
    assert res[:ok]
    assert @provider.complete_called
    refute @provider.stream_chat_called
  end

  def test_send_llm_request_uses_streaming_when_supported_and_enabled
    streaming_provider = StreamingMockProvider.new(['{"tool": "finish", "args": { "message": "stream finish" }}'])
    loop_inst = create_loop(provider: streaming_provider)

    res = loop_inst.run("Stream test")
    assert res[:ok]
    assert streaming_provider.stream_chat_called
  end

  def test_send_llm_request_disables_streaming_when_opts_or_config_override
    streaming_provider = StreamingMockProvider.new(['{"tool": "finish", "args": { "message": "forced batch finish" }}'])
    mock_shell = Struct.new(:buffer_manager, :snapshot_store, :context_index, :lsp_manager, :config, :runtime_manager, :commands).new(
      @buffer_manager, nil, nil, nil, { "llm.stream" => false }, nil, nil
    )
    loop_inst = create_loop(provider: streaming_provider, shell: mock_shell)

    res = loop_inst.run("Forced batch test")
    assert res[:ok]
    assert streaming_provider.complete_called
    refute streaming_provider.stream_chat_called
  end

  # --- Batch Error Recovery & Context Compaction ---

  def test_execute_batch_request_recovers_on_context_overflow_exception
    fail_count = 0
    recovering_provider = Class.new(Rubik::LLM::BaseProvider) do
      define_method(:complete) do |_messages, _opts = {}|
        fail_count += 1
        raise StandardError, "maximum context length exceeded" if fail_count == 1

        Rubik::LLM::Response.new(text: '{"tool": "finish", "args": { "message": "recovered" }}')
      end
    end.new

    loop_inst = create_loop(provider: recovering_provider)
    res = loop_inst.run("Overflow test")

    assert res[:ok]
    assert_equal "recovered", res[:output]
    assert_equal 2, fail_count
    compact_event = @events.find { |e| e[:type] == :emergency_compact }
    refute_nil compact_event
    assert_includes compact_event[:reason], "maximum context length"
  end

  def test_execute_batch_request_raises_non_context_error
    failing_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        raise StandardError, "API authentication failed"
      end
    end.new

    loop_inst = create_loop(provider: failing_provider)
    assert_raises(StandardError) do
      loop_inst.run("Auth failure test")
    end
  end

  # --- Empty Response Handling ---

  def test_empty_response_nudge_then_termination
    empty_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(text: "")
      end
    end.new

    loop_inst = create_loop(provider: empty_provider)
    res = loop_inst.run("Empty response test")

    refute res[:ok]
    assert_includes res[:error], "Empty response from model"
    assert_equal 2, loop_inst.empty_response_count

    nudge_msg = loop_inst.history.find { |m| m[:role] == "user" && m[:content].include?("Your last response was empty") }
    refute_nil nudge_msg
  end

  # --- Step Budget Limit Enforcement ---

  def test_exceeding_max_steps_returns_error
    File.write(File.join(@temp_dir, "test.txt"), "hello")
    tool_calling_provider = Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(
          text: "Reading file...",
          tool_calls: [{ "tool" => "read_file", "args" => { "path" => "test.txt" } }]
        )
      end
    end.new

    loop_inst = create_loop(provider: tool_calling_provider, max_steps: 3)
    res = loop_inst.run("Infinite tool loop test")

    refute res[:ok]
    assert_includes res[:error], "Max steps budget exceeded (3)"
    assert_equal 3, res[:steps]
  end

  # --- Emergency Compaction & Notification ---

  def test_emergency_compact_and_notify
    loop_inst = create_loop
    loop_inst.history << { role: "system", content: "sys" }
    loop_inst.history << { role: "user", content: "very long " * 100 }

    loop_inst.emergency_compact_and_notify!("Test overflow")

    event = @events.find { |e| e[:type] == :emergency_compact }
    refute_nil event
    assert_equal "Test overflow", event[:reason]
  end

  # --- Process Response & Thought Events ---

  def test_process_step_response_emits_message_for_text_only
    loop_inst = create_loop
    res = Rubik::LLM::Response.new(text: "Hello world, task finished.")

    result = loop_inst.send(:process_step_response, res)
    assert result[:ok]
    assert_equal "Hello world, task finished.", result[:output]

    msg_event = @events.find { |e| e[:type] == :message }
    refute_nil msg_event
    assert_equal "Hello world, task finished.", msg_event[:content]
  end

  def test_process_step_response_emits_llm_thought_when_calling_non_finish_tool
    loop_inst = create_loop
    res = Rubik::LLM::Response.new(
      text: "I should read the file first.",
      tool_calls: [{ "tool" => "read_file", "args" => { "path" => "test.txt" } }]
    )

    loop_inst.send(:process_step_response, res)

    thought_event = @events.find { |e| e[:type] == :llm_thought }
    refute_nil thought_event
    assert_equal "I should read the file first.", thought_event[:content]
  end

  # --- Plan Mode: code-level tool gating (not just prompt-level) ---

  def test_plan_mode_never_executes_tool_calls_from_text
    provider = MockProvider.new(['{"tool": "write_file", "args": {"path": "evil.rb", "content": "pwned"}}'])
    loop_inst = create_loop(provider: provider)

    result = loop_inst.run("plan the refactor", plan_only: true)

    assert result[:ok]
    assert_includes result[:output], "write_file"
    refute File.exist?(File.join(@temp_dir, "evil.rb")), "Plan mode must not execute parsed tool calls"
    refute loop_inst.history.any? { |m| m[:role] == "tool" }, "No tool results may be recorded in plan mode"
  end

  def test_plan_mode_system_prompt_omits_toolbelt
    provider = MockProvider.new(["1. Step one\n2. Step two"])
    loop_inst = create_loop(provider: provider)

    loop_inst.run("plan", plan_only: true)

    system_msg = loop_inst.history.first
    assert_equal "system", system_msg[:role]
    refute_includes system_msg[:content], "You can call tools"
    refute_includes system_msg[:content], "native function calling"
  end

  def test_plan_mode_nudges_on_empty_text_and_bails_after_two
    provider = MockProvider.new([
                                  Rubik::LLM::Response.new(text: "", tool_calls: [{ "tool" => "read_file", "args" => {} }]),
                                  Rubik::LLM::Response.new(text: "")
                                ])
    loop_inst = create_loop(provider: provider)

    result = loop_inst.run("plan", plan_only: true)

    refute result[:ok]
    assert_equal "Empty response from model", result[:error]
    nudge = loop_inst.history.find { |m| m[:role] == "user" && m[:content].to_s.include?("Plan mode: tool calls are disabled") }
    refute_nil nudge, "Model must be nudged toward a text-only plan"
  end

  def test_default_mode_publishes_compact_native_tool_section
    provider = MockProvider.new(['{"tool": "finish", "args": { "message": "done" }}'])
    loop_inst = create_loop(provider: provider)

    loop_inst.run("do it")

    system_msg = loop_inst.history.first
    assert_includes system_msg[:content], "native function calling"
    assert_includes system_msg[:content], "read_file"
    # Full JSON schema dump must not be duplicated into the prompt anymore
    refute_includes system_msg[:content], '"parameters"'
  end
end
