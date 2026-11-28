# frozen_string_literal: true

require_relative "../test_helper"

class TestReplStream < Minitest::Test
  class MockStreamProvider < Rubik::LLM::BaseProvider
    attr_reader :stream_count, :complete_count

    def initialize(chunks: [], complete_text: "Batch output", raise_interrupt: false)
      super()
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

  def test_same_provider_is_not_reprovided_on_every_turn
    # #685: a re-provide of the identical object reconciles every active
    # fiber injecting llm_client; a routed turn must not pay that cost.
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "ok", done: false),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 1, output_tokens: 1 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    stub_router_with_provider(provider)
    provides = []
    manager = @shell.runtime_manager
    original = manager.method(:provide)
    manager.define_singleton_method(:provide) do |name, service|
      provides << name if name == :llm_client
      original.call(name, service)
    end

    @shell.execute_free_text("turn one")
    @shell.execute_free_text("turn two")

    assert_empty provides, "routing to the same provider must not re-provide: #{provides.inspect}"
  end

  def test_different_provider_is_reprovided
    chunks = [Rubik::LLM::Chunk.new(usage: { input_tokens: 1, output_tokens: 1 }, done: true)]
    first = MockStreamProvider.new(chunks: chunks)
    second = MockStreamProvider.new(chunks: chunks.map(&:dup))
    call = 0
    router = Object.new
    router.define_singleton_method(:route) do |*_a, **_kw|
      call += 1
      { role: "default", model: "mock-model", provider: call == 1 ? first : second,
        context_limit: 4096, max_output_tokens: 1024 }
    end
    @shell.instance_variable_set(:@router, router)
    @shell.runtime_manager.provide(:llm_client, first)
    provides = []
    manager = @shell.runtime_manager
    original = manager.method(:provide)
    manager.define_singleton_method(:provide) do |name, service|
      provides << name if name == :llm_client
      original.call(name, service)
    end

    @shell.execute_free_text("turn one")
    @shell.instance_variable_set(:@conversation_route_stamp, nil) # !model-style reset
    @shell.execute_free_text("turn two")

    assert_equal [:llm_client], provides, "an identity change must still re-provide"
  end

  def test_late_settle_error_does_not_write_a_contradictory_failed_turn
    # #686: the answer is already in history when the tool-history merge
    # raises. The rescue must log the late error, not append a failed row.
    chunks = [
      Rubik::LLM::Chunk.new(text_delta: "Delivered answer", done: false),
      Rubik::LLM::Chunk.new(usage: { input_tokens: 1, output_tokens: 1 }, done: true)
    ]
    provider = MockStreamProvider.new(chunks: chunks)
    stub_router_with_provider(provider)
    calls = 0
    @shell.define_singleton_method(:merge_unseen_turn_tool_history!) do |*_args|
      calls += 1
      raise "late merge boom" if calls == 1
    end

    @shell.execute_free_text("question")

    rows = @shell.conversation_history
    refute rows.any? { |r| r[:content].to_s.include?("[Turn failed") },
           "a late error must not contradict the delivered answer: #{rows.inspect}"
    assert(rows.any? { |r| r[:content].to_s == "Delivered answer" })
  end

  def test_repl_execute_free_text_interrupt_handling
    provider = MockStreamProvider.new(raise_interrupt: true)
    stub_router_with_provider(provider)

    @shell.execute_free_text("Task to be cancelled")

    out_str = @output.string
    assert_includes out_str, "Task cancelled by user (^C)"
  end
end
