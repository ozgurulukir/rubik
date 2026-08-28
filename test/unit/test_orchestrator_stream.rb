# frozen_string_literal: true

require_relative "../test_helper"

class TestOrchestratorStream < Minitest::Test
  class MockStreamingProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_calls, :complete_calls

    def initialize(chunks: [], complete_response: nil, error_on_first_stream: nil)
      @chunks = chunks
      @complete_response = complete_response || Rubik::LLM::Response.new(text: "Batch response", usage: { input_tokens: 10, output_tokens: 5 })
      @error_on_first_stream = error_on_first_stream
      @stream_calls = 0
      @complete_calls = 0
    end

    def stream_chat(messages, opts = {}, &block)
      @stream_calls += 1
      if @error_on_first_stream && @stream_calls == 1
        raise Rubik::LLM::ClientError, @error_on_first_stream
      end

      if block
        @chunks.each { |c| block.call(c) }
      else
        @chunks.to_enum
      end
    end

    def complete(messages, opts = {})
      @complete_calls += 1
      @complete_response
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_stream_test")
    @tool_registry = Rubik::Tools::Registry.new
    @tool_registry.register(Rubik::Tools::FinishTool.new)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_streaming_request_delivers_chunks_and_builds_response
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Hello "),
      Rubik::LLM::Chunk.new(text_delta: "streaming "),
      Rubik::LLM::Chunk.new(text_delta: "world!"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 20, output_tokens: 6 }, done: true)
    ]
    provider = MockStreamingProvider.new(chunks: chunks)
    events = []

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry,
      on_step: ->(step_info) { events << step_info }
    )

    res = loop_orchestrator.run("Say hello")
    assert res[:ok]
    assert_equal "Hello streaming world!", res[:output]

    chunk_deltas = events.select { |e| e[:type] == :chunk }.map { |e| e[:delta] }
    assert_equal ["Hello ", "streaming ", "world!"], chunk_deltas
    assert events.any? { |e| e[:type] == :chunk_end }
    assert_equal 1, provider.stream_calls
    assert_equal 0, provider.complete_calls
    assert_equal 20, res[:tokens][:input]
    assert_equal 6, res[:tokens][:output]
  end

  def test_streaming_request_assembles_tool_calls_without_chunk_pollution
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: [
        {
          "index" => 0,
          "name" => "finish",
          "arguments_delta" => '{"message":"Task finished successfully"}'
        }
      ]),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 30, output_tokens: 15 }, done: true)
    ]
    provider = MockStreamingProvider.new(chunks: chunks)
    events = []

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry,
      on_step: ->(step_info) { events << step_info }
    )

    res = loop_orchestrator.run("Finish task")
    assert res[:ok]
    assert_equal "Task finished successfully", res[:output]

    # Tool JSON chunks should not be emitted as :chunk text deltas
    assert_empty events.select { |e| e[:type] == :chunk }
    refute events.any? { |e| e[:type] == :chunk_end }
    assert events.any? { |e| e[:type] == :finish }
  end

  def test_batch_mode_when_stream_is_false
    provider = MockStreamingProvider.new
    events = []
    config = Rubik::Config.new(root_dir: @temp_dir)
    config.set("llm.stream", false)

    shell = Object.new
    shell.define_singleton_method(:config) { config }
    shell.define_singleton_method(:buffer_manager) { nil }
    shell.define_singleton_method(:snapshot_store) { nil }
    shell.define_singleton_method(:context_index) { nil }
    shell.define_singleton_method(:lsp_manager) { nil }
    shell.define_singleton_method(:runtime_manager) { nil }

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry,
      shell: shell,
      on_step: ->(step_info) { events << step_info }
    )

    res = loop_orchestrator.run("Run batch task")
    assert res[:ok]
    assert_equal "Batch response", res[:output]

    assert_equal 0, provider.stream_calls
    assert_equal 1, provider.complete_calls
    assert_empty events.select { |e| e[:type] == :chunk }
  end

  def test_emergency_compaction_recovery_during_streaming
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Recovered successfully!"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 4 }, done: true)
    ]
    provider = MockStreamingProvider.new(
      chunks: chunks,
      error_on_first_stream: "maximum context length exceeded"
    )
    events = []

    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry,
      on_step: ->(step_info) { events << step_info }
    )

    res = loop_orchestrator.run("Trigger overflow and recover")
    assert res[:ok]
    assert_equal "Recovered successfully!", res[:output]

    assert_equal 2, provider.stream_calls
    assert events.any? { |e| e[:type] == :emergency_compact }
    assert_equal ["Recovered successfully!"], events.select { |e| e[:type] == :chunk }.map { |e| e[:delta] }
  end

  def test_streaming_request_handles_malformed_or_non_hash_json_args_gracefully
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: [
        {
          "index" => 0,
          "name" => "finish",
          "arguments_delta" => "12345" # Not a JSON object (number)
        }
      ]),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 2 }, done: true)
    ]
    provider = MockStreamingProvider.new(chunks: chunks)
    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry
    )

    res = loop_orchestrator.run("Finish with scalar JSON")
    assert res[:ok]
    assert_equal false, res[:streamed]
  end

  def test_streamed_flag_reflects_actual_text_streaming
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Live stream output"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 3 }, done: true)
    ]
    provider = MockStreamingProvider.new(chunks: chunks)
    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry
    )

    res = loop_orchestrator.run("Live text")
    assert res[:ok]
    assert_equal true, res[:streamed]
    assert_equal "Live stream output", res[:output]
  end

  def test_stream_manager_builds_response_directly
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Direct "),
      Rubik::LLM::Chunk.new(text_delta: "assembly"),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "call_1", "name" => "finish", "arguments_delta" => "{\"message\":\"done\"}" }),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 7, output_tokens: 3 }, done: true)
    ]
    provider = MockStreamingProvider.new(chunks: chunks)
    loop_orchestrator = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: @tool_registry
    )

    res = loop_orchestrator.stream_manager.build_response_from_chunks(chunks, streamed_text: true)

    assert_equal "Direct assembly", res.text
    assert_equal 1, res.tool_calls.size
    assert_equal "finish", res.tool_calls.first["tool"]
    assert_equal({ "message" => "done" }, res.tool_calls.first["args"])
    assert_equal 7, res.usage[:input_tokens]
    assert res.streamed
  end
end

