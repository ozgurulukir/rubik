# frozen_string_literal: true

require_relative "../test_helper"
require "monitor"

# G13 remainder: orchestrator/subagent error paths pinned against in-memory
# doubles — StepRunner's provider/inbox/tool-dispatch arms, the supervisor's
# router-failure fallback, transcript save failure, and Instance's context
# cleanup failure recording. No provider or process is ever contacted.
class TestSubagentErrorPaths < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_subagent_err")
    @config = Rubik::Config.new(root_dir: @tmp)
    @registry = Rubik::Tools::Registry.new
    @context = Rubik::Runtime::Context.new
  end

  def teardown
    @context&.dispose unless @context&.disposed?
    remove_temp_dir(@tmp) if File.directory?(@tmp)
  end

  def build_instance
    Rubik::Orchestrator::Subagent::Instance.new(
      id: "subagent-err-1",
      parent_id: "agent-0",
      role: "Error Path Probe",
      type_name: "research",
      prompt: "probe",
      context: @context,
      tool_registry: @registry,
      context_limit: 1_000,
      config: @config,
      root_dir: @tmp
    )
  end

  def test_invoke_provider_without_complete_or_chat_raises_typed_error
    inst = build_instance
    inst.instance_variable_set(:@provider, Object.new)

    err = assert_raises(RuntimeError) { inst.send(:invoke_provider, {}) }
    assert_includes err.message, "does not support complete or chat"
  end

  def test_drain_inbox_with_empty_queue_breaks_cleanly
    inst = build_instance
    # Race double: queue reports empty but pop(true) raises ThreadError —
    # the exact race the rescue/break arm exists for.
    racy_inbox = Object.new
    racy_inbox.define_singleton_method(:empty?) { true }
    racy_inbox.define_singleton_method(:pop) { |_| raise ThreadError, "queue empty" }
    inst.instance_variable_set(:@inbox, racy_inbox)

    inst.send(:drain_inbox_into_history)

    assert_empty inst.history
  end

  def test_dispatch_subagent_tool_reports_execution_error_as_string
    inst = build_instance
    boom = Object.new
    boom.define_singleton_method(:execute) { |_| raise "backend gone" }

    result = inst.send(:dispatch_subagent_tool, boom, "boom_tool", {})

    assert_kind_of Rubik::Tools::Result, result
    assert_includes result.output, "Tool execution error"
    assert_includes result.output, "backend gone"
    assert_equal :error, result.status, "execution errors carry the error status for the canonical tool row"
  end

  def test_supervisor_router_failure_falls_back_to_configured_provider
    router = Object.new
    router.define_singleton_method(:route) { |**| raise "router down" }
    provider = Object.new
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @context,
      provider: provider,
      router: router,
      config: @config,
      root_dir: @tmp
    )

    pair = nil
    captured = capture_io do
      pair = supervisor.send(:resolve_provider_and_model, "pro")
    end

    assert_equal [provider, "pro"], pair
    assert_includes captured[1], "router failed"
    assert_includes captured[1], "router down"
  end

  def test_transcript_save_failure_warns_and_returns_nil
    guard_file = File.join(@tmp, "guard.txt")
    File.write(guard_file, "x") # a FILE where a directory is required

    res = nil
    captured = capture_io do
      res = Rubik::Orchestrator::Subagent::TranscriptFormatter.save!(
        File.join(guard_file, "t.jsonl"), [{ "a" => 1 }], Monitor.new
      )
    end

    assert_nil res
    assert_includes captured[1], "Failed to save"
  end

  def test_cleanup_context_records_dispose_failure_once
    inst = build_instance
    dispose_calls = 0
    fake_ctx = Object.new
    fake_ctx.define_singleton_method(:disposed?) { false }
    fake_ctx.define_singleton_method(:dispose) do
      dispose_calls += 1
      raise "ctx boom"
    end
    inst.instance_variable_set(:@context, fake_ctx)

    inst.send(:cleanup_context)

    assert_includes inst.instance_variable_get(:@last_error), "ctx boom"
    inst.send(:cleanup_context) # idempotent under the cleaned-up flag
    assert_equal 1, dispose_calls, "the second cleanup must not dispose again"
  end
end
