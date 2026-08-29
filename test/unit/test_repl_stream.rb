# frozen_string_literal: true

require_relative "../test_helper"

class TestReplStream < Minitest::Test
  class MockStreamProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_count, :complete_count

    def initialize(chunks: [], complete_text: "Batch output", raise_interrupt: false)
      @chunks = chunks
      @complete_text = complete_text
      @raise_interrupt = raise_interrupt
      @stream_count = 0
      @complete_count = 0
    end

    def stream_chat(_messages, _opts = {}, &block)
      @stream_count += 1
      raise Interrupt if @raise_interrupt

      if block
        @chunks.each { |c| block.call(c) }
      else
        @chunks.to_enum
      end
    end

    def complete(_messages, _opts = {})
      @complete_count += 1
      raise Interrupt if @raise_interrupt

      Rubik::LLM::Response.new(text: @complete_text, usage: { input_tokens: 10, output_tokens: 5 })
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_repl_stream_test")
    @temp_home = Dir.mktmpdir("rubik_repl_stream_home")
    @output = StringIO.new
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @shell = Rubik::REPL::Shell.new(
      config: @config,
      output: @output,
      root_dir: @temp_dir
    )
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if File.directory?(@temp_home)
  end

  def stub_router_with_provider(provider)
    mock_router = Object.new
    mock_router.define_singleton_method(:route) do |*_a, **_kw|
      { role: "default", model: "mock-model", provider: provider,
        context_limit: 4096, max_output_tokens: 1024 }
    end
    @shell.instance_variable_set(:@router, mock_router)
    @shell.runtime_manager.provide(:llm_client, provider)
    @shell.runtime_manager.provide(:llm, provider)
  end

  def test_repl_execute_free_text_streams_live_and_avoids_double_print
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Live "),
      Rubik::LLM::Chunk.new(text_delta: "token "),
      Rubik::LLM::Chunk.new(text_delta: "output!"),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 10, output_tokens: 3 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    stub_router_with_provider(provider)

    @shell.execute_free_text("Test live streaming")

    out_str = @output.string
    assert_includes out_str, "Live token output!"
    # Ensure double-print guard prevents duplicate printing
    occurrences = out_str.scan("Live token output!").size
    assert_equal 1, occurrences, "Expected streamed text to appear exactly once, got #{occurrences}"
    assert_equal 1, provider.stream_count
    assert_equal 0, provider.complete_count
  end

  def test_repl_execute_free_text_in_batch_mode_prints_output_once
    @config.set("llm.stream", false)
    provider = MockStreamProvider.new(complete_text: "Batch mode completed successfully")
    stub_router_with_provider(provider)

    @shell.execute_free_text("Test batch mode")

    out_str = @output.string
    assert_includes out_str, "Batch mode completed successfully"
    occurrences = out_str.scan("Batch mode completed successfully").size
    assert_equal 1, occurrences
    assert_equal 0, provider.stream_count
    assert_equal 1, provider.complete_count
  end

  def test_repl_execute_free_text_interrupt_handling
    provider = MockStreamProvider.new(raise_interrupt: true)
    stub_router_with_provider(provider)

    @shell.execute_free_text("Task to be cancelled")

    out_str = @output.string
    assert_includes out_str, "Görev kullanıcı tarafından iptal edildi (^C)"
  end
end
