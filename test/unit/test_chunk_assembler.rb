# frozen_string_literal: true

require_relative "../test_helper"
require "rubik/llm/chunk_assembler"
require "rubik/llm/provider"

# Plan 61 D-4/D-10: chunk assembly is shared by the live stream manager and
# the BaseProvider#complete batch fallback — both paths must produce
# identical text, tool_calls and usage, and malformed tool-call arguments
# must surface as diagnostics instead of vanishing.
class TestChunkAssembler < Minitest::Test
  def test_text_and_usage_assembly
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Hello "),
      Rubik::LLM::Chunk.new(text_delta: "world"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 7, output_tokens: 3 }, done: true)
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks, streamed: true)
    assert_equal "Hello world", res.text
    assert_equal({ input_tokens: 7, output_tokens: 3 }, res.usage)
    assert_empty res.tool_calls
    assert_equal true, res.streamed
  end

  def test_arguments_delta_accumulation
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "t1", "name" => "write_file", "arguments_delta" => '{"pat' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "arguments_delta" => 'h": "a.rb"}' })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_equal 1, res.tool_calls.size
    assert_equal "write_file", res.tool_calls[0]["tool"]
    assert_equal({ "path" => "a.rb" }, res.tool_calls[0]["args"])
  end

  def test_wholesale_args_delta_ollama_style
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "t9", "name" => "finish", "args" => { "message" => "done" } })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_equal 1, res.tool_calls.size
    assert_equal({ "message" => "done" }, res.tool_calls[0]["args"])
    assert_equal "t9", res.tool_calls[0]["id"]
  end

  def test_malformed_args_json_fires_diagnostic_callback
    received = []
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "t2", "name" => "run_tests", "arguments_delta" => '{"trunc' })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks, on_malformed_args: ->(tool, frag) { received << [tool, frag] })
    assert_equal [["run_tests", '{"trunc']], received
    assert_equal({}, res.tool_calls[0]["args"])
  end

  def test_empty_chunks_yield_empty_usage
    res = Rubik::LLM::ChunkAssembler.build([])
    assert_equal "", res.text
    assert_equal({}, res.usage)
    assert_empty res.tool_calls
  end

  def test_estimate_fallbacks_used_without_usage_chunk
    chunks = [Rubik::LLM::Chunk.new(text_delta: "abc")]
    res = Rubik::LLM::ChunkAssembler.build(
      chunks,
      estimate_history: -> { 42 },
      estimate_text: ->(_t) { 5 }
    )
    assert_equal({ input_tokens: 42, output_tokens: 5 }, res.usage)
  end

  # Plan 61 D-4: a stream-only custom provider routed through batch mode
  # used to lose every tool call (tool_calls: []).
  def test_base_provider_complete_fallback_preserves_tool_calls
    provider = Class.new(Rubik::LLM::BaseProvider) do
      def stream_chat(messages, opts = {}, &block)
        return to_enum(:stream_chat, messages, opts) unless block

        block.call(Rubik::LLM::Chunk.new(text_delta: "thinking..."))
        block.call(Rubik::LLM::Chunk.new(
                     tool_use_delta: { "index" => 0, "id" => "t7", "name" => "list_files", "args" => { "path" => "." } },
                     usage: { input_tokens: 11, output_tokens: 4 },
                     done: true
                   ))
      end
    end.new

    res = provider.complete([{ role: "user", content: "list" }])
    assert_equal "thinking...", res.text
    assert_equal 1, res.tool_calls.size
    assert_equal "list_files", res.tool_calls[0]["tool"]
    assert_equal({ "path" => "." }, res.tool_calls[0]["args"])
    assert_equal({ input_tokens: 11, output_tokens: 4 }, res.usage)
  end
end
