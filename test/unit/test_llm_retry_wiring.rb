# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/orchestrator/loop"

class TestLLMRetryWiring < Minitest::Test
  FakeToolRegistry = Struct.new(:schemas)

  def build_loop(provider:, on_step:)
    tool_registry = FakeToolRegistry.new([])
    tool_registry.define_singleton_method(:get) { |_name| nil }

    Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: tool_registry,
      max_steps: 2,
      on_step: on_step
    )
  end

  def test_loop_wires_on_retry_to_on_step
    steps = []
    on_step = ->(info) { steps << info }

    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      opts[:on_retry]&.call(1, 2, "Errno::ECONNRESET")
      raise Rubik::LLM::ClientError, "boom"
    end

    loop = build_loop(provider: provider, on_step: on_step)
    assert_raises(Rubik::LLM::ClientError) { loop.run("task") }

    retry_step = steps.find { |s| s[:type] == :llm_retry }
    refute_nil retry_step, "on_step must receive an :llm_retry event"
    assert_equal 1, retry_step[:attempt]
    assert_equal 2, retry_step[:max]
    assert_equal "Errno::ECONNRESET", retry_step[:reason]
  end

  def test_loop_merges_on_retry_without_clobbering_caller_opts
    seen_opts = nil
    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, opts = {}|
      seen_opts = opts
      raise Rubik::LLM::ClientError, "boom"
    end

    loop = Rubik::Orchestrator::Loop.new(
      provider: provider,
      tool_registry: FakeToolRegistry.new([]),
      max_steps: 1
    )
    # simulate the caller-side opts path: run() builds opts with :model etc.
    loop.instance_variable_set(:@model, "test-model")
    assert_raises(Rubik::LLM::ClientError) { loop.run("task") }

    assert_kind_of Proc, seen_opts[:on_retry], "provider opts must gain an on_retry proc"
    assert_equal "test-model", seen_opts[:model]
  end
end
