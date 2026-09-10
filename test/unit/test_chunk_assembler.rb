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

  # Plan 85 / InternLM: lmdeploy streaming aynı index'i yeni bir call için
  # yeniden kullanabilir (aynı index, farklı id). Eski davranış arguments'ları
  # tek args_json'e karıştırıp bozuk JSON üretiyordu; artık farklı id → ayrı slot.
  def test_same_index_new_call_id_splits_into_two_calls
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tA", "name" => "list_files", "arguments_delta" => '{"path":"."}' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tB", "name" => "read_file",   "arguments_delta" => '{"path":"a.rb"' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tB",                          "arguments_delta" => ',"line":10}' })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_equal 2, res.tool_calls.size
    assert_equal "list_files", res.tool_calls[0]["tool"]
    assert_equal "read_file", res.tool_calls[1]["tool"]
    # arguments karışmamalı: tB iki delta ile birleşir, tA ayrı kalır.
    assert_equal({ "path" => "." }, res.tool_calls[0]["args"])
    assert_equal({ "path" => "a.rb", "line" => 10 }, res.tool_calls[1]["args"])
  end

  # ID'siz başlayan call'a ID sonradan gelirse, bu yeni bir call değil aynı call'dır
  # — split'e yol açmamalı (umbrella: boş/nil id bir call'ı tanımlamaz).
  def test_late_or_missing_id_does_not_split_same_call
    chunks = [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "name" => "list_files", "arguments_delta" => '{"path":' }), # id yok
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tA",           "arguments_delta" => '"."' }),      # id sonradan gelir
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "",             "arguments_delta" => "}" })         # boş string id
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_equal 1, res.tool_calls.size
    assert_equal "list_files", res.tool_calls[0]["tool"]
    assert_equal({ "path" => "." }, res.tool_calls[0]["args"])
  end

  # Red-team B1: tool name'siz ama arguments üretilmiş yarım call, sessizce silinmek
  # yerine args içeriği metne bağlanır — böylece text boş kalmaz (empty response'tan
  # kaçınılır) ve bilgi kaybolmaz.
  def test_tool_name_missing_but_args_surfaces_in_text
    chunks = [
      Rubik::LLM::Chunk.new(raw: {
                              "message" => { "tool_calls" => [{ "id" => "x1", "function" => { "name" => nil, "arguments" => { "path" => "." } } }] }
                            })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_empty res.tool_calls
    refute res.text.empty?, "yarım tool call args metne bağlanmalı (empty response önlenir)"
    assert_includes res.text, "[Incomplete tool call — arguments:"
  end

  # Red-team B2: content_block_start (Anthropic-style) yolu da aynı index üzerinde
  # farklı id geldiğinde ayrı slot açmalı — tool_use_delta ile tutarlı.
  def test_content_block_start_same_index_new_id_splits
    chunks = [
      Rubik::LLM::Chunk.new(raw: { "type" => "content_block_start", "index" => 0,
                                   "content_block" => { "type" => "tool_use", "id" => "cA", "name" => "list_files" } }),
      Rubik::LLM::Chunk.new(raw: { "type" => "content_block_start", "index" => 0,
                                   "content_block" => { "type" => "tool_use", "id" => "cB", "name" => "read_file" } })
    ]
    res = Rubik::LLM::ChunkAssembler.build(chunks)
    assert_equal 2, res.tool_calls.size
    assert_equal "list_files", res.tool_calls[0]["tool"]
    assert_equal "read_file", res.tool_calls[1]["tool"]
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

  # ── Plan 87 E-2: golden snapshots (pinned BEFORE the incremental
  #    rewrite) + shared fixtures for the build ↔ incremental equivalence ──

  # Fixture A: text + reasoning + split tool args + usage + finish reason.
  def fixture_a_chunks
    [
      Rubik::LLM::Chunk.new(reasoning_delta: "let me "),
      Rubik::LLM::Chunk.new(reasoning_delta: "think"),
      Rubik::LLM::Chunk.new(text_delta: "Listing "),
      Rubik::LLM::Chunk.new(text_delta: "files."),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "g1", "name" => "list_files", "arguments_delta" => '{"path"' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "arguments_delta" => ': "."}' }),
      Rubik::LLM::Chunk.new(raw: { "choices" => [{ "finish_reason" => "tool_calls" }] }),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 100, output_tokens: 20 }, done: true)
    ]
  end

  # Fixture B: composite-key slot split on the same index (Red-team B2).
  def fixture_b_chunks
    [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tA", "name" => "list_files", "arguments_delta" => '{"path":"."}' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tB", "name" => "read_file", "arguments_delta" => '{"path":"a.rb"' }),
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "tB", "arguments_delta" => ',"line":10}' })
    ]
  end

  # Fixture C: Anthropic content_block_start + wholesale raw message args.
  def fixture_c_chunks
    [
      Rubik::LLM::Chunk.new(raw: { "type" => "content_block_start", "index" => 0,
                                   "content_block" => { "type" => "tool_use", "id" => "cA", "name" => "list_files" } }),
      Rubik::LLM::Chunk.new(raw: { "message" => { "tool_calls" => [{ "id" => "m1",
                                                                     "function" => { "name" => "run_tests", "arguments" => { "suite" => "unit" } } }] } })
    ]
  end

  # Fixture D: finish promotion — finish_reason lives in an earlier chunk
  # while the LAST non-empty raw carries none.
  def fixture_d_chunks
    [
      Rubik::LLM::Chunk.new(text_delta: "Truncated..."),
      Rubik::LLM::Chunk.new(raw: { "choices" => [{ "finish_reason" => "length" }] }),
      Rubik::LLM::Chunk.new(raw: { "model" => "test-model" }, usage: { input_tokens: 10, output_tokens: 4096 }, done: true)
    ]
  end

  # Fixture E: malformed args JSON → diagnostic callback; degenerate
  # (name-less) raw call's args append to text.
  def fixture_e_chunks
    [
      Rubik::LLM::Chunk.new(tool_use_delta: { "index" => 0, "id" => "t2", "name" => "run_tests", "arguments_delta" => '{"trunc' }),
      Rubik::LLM::Chunk.new(raw: {
                              "message" => { "tool_calls" => [{ "id" => "x1", "function" => { "name" => nil, "arguments" => { "path" => "." } } }] }
                            })
    ]
  end

  def test_golden_full_stream_shape
    res = Rubik::LLM::ChunkAssembler.build(fixture_a_chunks, streamed: true)
    assert_equal "Listing files.", res.text
    assert_equal "let me think", res.thought
    assert_equal [{ "id" => "g1", "tool" => "list_files", "args" => { "path" => "." } }], res.tool_calls
    assert_equal({ input_tokens: 100, output_tokens: 20 }, res.usage)
    assert_equal({ "choices" => [{ "finish_reason" => "tool_calls" }] }, res.raw)
    assert_equal true, res.streamed
  end

  def test_golden_composite_key_slot_split
    res = Rubik::LLM::ChunkAssembler.build(fixture_b_chunks)
    assert_equal [
      { "id" => "tA", "tool" => "list_files", "args" => { "path" => "." } },
      { "id" => "tB", "tool" => "read_file", "args" => { "path" => "a.rb", "line" => 10 } }
    ], res.tool_calls
    assert_equal "", res.text
    assert_nil res.thought
    assert_equal({}, res.usage)
  end

  def test_golden_raw_paths_produce_wholesale_args
    res = Rubik::LLM::ChunkAssembler.build(fixture_c_chunks)
    assert_equal [
      { "id" => "cA", "tool" => "list_files", "args" => {} },
      { "id" => "m1", "tool" => "run_tests", "args" => { "suite" => "unit" } }
    ], res.tool_calls
  end

  def test_golden_finish_reason_promoted_from_earlier_chunk
    res = Rubik::LLM::ChunkAssembler.build(fixture_d_chunks, streamed: false)
    assert_equal "Truncated...", res.text
    assert_equal "length", res.raw["finish_reason"], "finish_reason from the earlier chunk must be promoted onto the last raw"
    assert_equal "test-model", res.raw["model"]
    assert_equal({ input_tokens: 10, output_tokens: 4096 }, res.usage)
    assert_equal false, res.streamed
  end

  def test_golden_malformed_and_degenerate_paths
    received = []
    res = Rubik::LLM::ChunkAssembler.build(fixture_e_chunks, on_malformed_args: ->(tool, frag) { received << [tool, frag] })
    assert_equal [["run_tests", '{"trunc']], received
    assert_equal({}, res.tool_calls[0]["args"])
    assert_empty res.tool_calls[1..]
    assert_includes res.text, "[Incomplete tool call — arguments: {\"path\":\".\"}]"
  end

  # Plan 87 E-2 equivalence: build now delegates to the incremental
  # Chunk::Assembler (SSOT), so this comparison is structural — the
  # absolute outputs are pinned independently by the golden tests above.
  def test_incremental_assembler_matches_build_for_all_fixtures
    fixtures = {
      "A: text+reasoning+delta+usage" => fixture_a_chunks,
      "B: composite key split" => fixture_b_chunks,
      "C: raw tool paths" => fixture_c_chunks,
      "D: finish promotion" => fixture_d_chunks,
      "E: malformed+degenerate" => fixture_e_chunks
    }
    fixtures.each do |label, chunks|
      via_build = Rubik::LLM::ChunkAssembler.build(chunks, streamed: true)
      asm = Rubik::LLM::Chunk::Assembler.new
      chunks.each { |c| asm.push(c) }
      via_incremental = asm.finish(streamed: true)

      assert_equal via_build.text, via_incremental.text, "#{label}: text"
      assert_equal via_build.thought, via_incremental.thought, "#{label}: thought"
      assert_equal via_build.tool_calls, via_incremental.tool_calls, "#{label}: tool_calls"
      assert_equal via_build.usage, via_incremental.usage, "#{label}: usage"
      assert_equal via_build.raw, via_incremental.raw, "#{label}: raw"
      assert_equal via_build.streamed, via_incremental.streamed, "#{label}: streamed"
    end
  end
end
