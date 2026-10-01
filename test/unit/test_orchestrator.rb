# frozen_string_literal: true

require_relative "../test_helper"

class TestOrchestrator < Minitest::Test
  class MockScriptProvider < Rubik::LLM::BaseProvider
    def initialize(responses)
      super()
      @responses = responses.dup
    end

    def complete(_messages, _opts = {})
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text)
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.new

    @registry.register(Rubik::Tools::ReadFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::WriteFileTool.new(@buffer_manager))
    @registry.register(Rubik::Tools::FinishTool.new)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_end_to_end_write_and_finish_loop
    script = [
      '{"tool": "write_file", "args": { "path": "fizzbuzz.rb", "content": "def fizzbuzz; end" }}',
      '{"tool": "finish", "args": { "message": "FizzBuzz module created in buffer" }}'
    ]

    provider = MockScriptProvider.new(script)
    # Plumbing test: exercises loop mechanics, not maestro policy — the
    # gate is off via config (policy lives in test_maestro_gate.rb).
    gate_off_shell = Struct.new(:lsp_manager, :buffer_manager, :config, :snapshot_store, :context_index, :runtime_manager)
                           .new(nil, @buffer_manager, { "subagents" => { "maestro_gate" => false } }, nil, nil, nil)
    orchestrator = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: @registry, shell: gate_off_shell)

    res = orchestrator.run("Write FizzBuzz module")
    assert res[:ok]
    assert_equal "FizzBuzz module created in buffer", res[:output]
    assert @buffer_manager.dirty?
    assert_equal "def fizzbuzz; end", @buffer_manager.read("fizzbuzz.rb")
  end

  def test_invalid_tool_retry_and_termination
    script = [
      '{"tool": "non_existent_tool", "args": {}}',
      '{"tool": "non_existent_tool", "args": {}}'
    ]

    provider = MockScriptProvider.new(script)
    orchestrator = Rubik::Orchestrator::Loop.new(provider: provider, tool_registry: @registry)

    res = orchestrator.run("Do something impossible")
    refute res[:ok]
    assert_includes res[:error], "Repeated invalid tool call"
  end

  def test_multi_step_read_and_format_messages_call_id_matching
    File.write(File.join(@temp_dir, "README.md"), "# Go-HaYaP Project\nOverview of progress payment system.")

    openai_prov = Rubik::LLM::OpenAICompatibleProvider.new(
      name: "test_openai",
      endpoint: "http://localhost:9999/v1/chat/completions",
      api_key: "dummy"
    )

    received_messages_step2 = nil
    step = 0

    mock_provider = Class.new(Rubik::LLM::BaseProvider) do
      define_method(:complete) do |messages, _opts = {}|
        step += 1
        if step == 1
          Rubik::LLM::Response.new(
            text: '{"tool": "read_file", "args": { "path": "README.md" }}'
          )
        else
          received_messages_step2 = messages
          Rubik::LLM::Response.new(
            text: "Go-HaYaP is a progress payment tracking system.",
            tool_calls: [{ "tool" => "finish", "args" => { "message" => "done" } }]
          )
        end
      end
    end.new

    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: mock_provider,
      tool_registry: @registry
    )

    res = orchestrator.run("What is this project about?")
    assert res[:ok]
    assert_equal "Go-HaYaP is a progress payment tracking system.", res[:output]

    # Verify formatting of messages for OpenAI maintains identical IDs
    formatted = openai_prov.send(:format_messages, received_messages_step2)
    assistant_msg = formatted.find { |m| m["role"] == "assistant" && m["tool_calls"] }
    tool_msg = formatted.find { |m| m["role"] == "tool" }

    refute_nil assistant_msg
    refute_nil tool_msg

    assistant_call_id = assistant_msg["tool_calls"].first["id"]
    tool_response_id = tool_msg["tool_call_id"]

    assert_equal assistant_call_id, tool_response_id
    refute_empty assistant_call_id
  end

  class MockLspManager
    attr_accessor :synced, :diag_called

    def initialize(synced: true)
      @synced = synced
      @diag_called = false
    end

    def enabled?
      true
    end

    def auto_diagnostics?
      true
    end

    def sync_buffer_file(_file_path, _content)
      @synced
    end

    def diagnostics_for(_file_path)
      @diag_called = true
      []
    end

    def status_summary
      { servers: {} }
    end

    def all_diagnostics
      {}
    end
  end

  def test_write_file_traversal_blocked_does_not_crash_orchestrator_with_lsp_enabled
    lsp_manager = MockLspManager.new(synced: true)

    script = [
      '{"tool": "write_file", "args": { "path": "/etc/hosts", "content": "blocked" }}',
      '{"tool": "finish", "args": { "message": "done after block" }}'
    ]
    provider = MockScriptProvider.new(script)
    mock_shell = Struct.new(:lsp_manager, :buffer_manager, :config, :snapshot_store, :context_index, :runtime_manager)
                       .new(lsp_manager, @buffer_manager, nil, nil, nil, nil)
    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @registry,
      shell: mock_shell
    )

    res = orchestrator.run("Attempt writing outside workspace")
    assert res[:ok]
    assert_equal "done after block", res[:output]
  end

  def test_non_lsp_file_does_not_wait_for_diagnostics
    lsp_manager = MockLspManager.new(synced: false)

    script = [
      '{"tool": "write_file", "args": { "path": "notes.txt", "content": "plain text" }}',
      '{"tool": "finish", "args": { "message": "done" }}'
    ]
    provider = MockScriptProvider.new(script)
    mock_shell = Struct.new(:lsp_manager, :buffer_manager, :config, :snapshot_store, :context_index, :runtime_manager)
                       .new(lsp_manager, @buffer_manager, nil, nil, nil, nil)
    orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @registry,
      shell: mock_shell
    )

    res = orchestrator.run("Write text note")
    assert res[:ok]
    refute lsp_manager.diag_called, "diagnostics_for should not be called when sync_buffer_file returns false"
  end
end
