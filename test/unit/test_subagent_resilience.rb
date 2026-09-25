# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentResilience < Minitest::Test
  MockResponse = Struct.new(:content, :tool_calls)

  class FlakyProvider
    attr_reader :calls

    def initialize(errors_to_raise: [], final_response: nil)
      @errors = errors_to_raise.dup
      @final_response = final_response || MockResponse.new("Success after recovery", [])
      @calls = 0
    end

    def complete(_history, _opts = {})
      @calls += 1
      err = @errors.shift
      raise err if err

      @final_response
    end

    def chat(history, **opts)
      complete(history, opts)
    end
  end

  def setup
    @root_context = Rubik::Runtime::Context.new
    @config = Rubik::Config.new
    @config.set("subagents.network_retry_count", 2)
    @config.set("subagents.network_backoff_base", 0.01)
    @config.set("subagents.error_wait_timeout", 0.1)
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
  end

  def test_transient_error_classification_matches_real_world_failures
    res = Rubik::Orchestrator::Subagent::Resilience

    # Real-world user errors
    inferx_server_err = Rubik::LLM::ClientError.new(
      'HTTP Request failed with code 500: {"error":{"message":"failed to submit chat request: ' \
      'engine-core error: engine core reported fatal failure","type":"server_error","param":null,"code":"server_error"}}'
    )
    inferx_timeout = Rubik::LLM::ClientError.new(
      "Network error during stream from model.inferx.net: Net::ReadTimeout with #<TCPSocket:(closed)>"
    )
    read_timeout_err = Rubik::LLM::ClientError.new(
      "read timeout after 30s calling model.inferx.net (model/server still working? request not retried)"
    )

    assert res.transient_error?(inferx_server_err)
    assert res.transient_error?(inferx_timeout)
    assert res.transient_error?(read_timeout_err)

    # Standard networking exceptions
    assert res.transient_error?(Net::ReadTimeout.new("read timeout"))
    assert res.transient_error?(Net::OpenTimeout.new("open timeout"))
    assert res.transient_error?(SocketError.new("getaddrinfo failed"))
    assert res.transient_error?(Errno::ECONNRESET.new("Connection reset by peer"))
    assert res.transient_error?(Errno::ECONNREFUSED.new("Connection refused"))
    assert res.transient_error?(EOFError.new("end of file reached"))
    assert res.transient_error?(Rubik::LLM::RateLimitError.new("HTTP 429 rate limited"))

    # Non-transient errors must NOT be classified as transient
    refute res.transient_error?(ArgumentError.new("invalid argument"))
    refute res.transient_error?(NoMethodError.new("undefined method foo"))
    refute res.transient_error?(Rubik::LLM::ClientError.new("HTTP 401 Unauthorized: Invalid API key"))
    refute res.transient_error?(Rubik::LLM::ClientError.new("HTTP 400 Bad Request: Invalid JSON payload"))
  end

  def test_retry_transient_retries_and_succeeds
    res = Rubik::Orchestrator::Subagent::Resilience
    attempts = 0
    err = Rubik::LLM::ClientError.new("HTTP Request failed with code 502: Bad Gateway")

    result = res.retry_transient(max_retries: 3, backoff_base: 0.001) do
      attempts += 1
      raise err if attempts < 3

      "success"
    end

    assert_equal "success", result
    assert_equal 3, attempts
  end

  def test_retry_transient_releases_gate_during_backoff
    res = Rubik::Orchestrator::Subagent::Resilience
    gate = Rubik::Orchestrator::Subagent::ConcurrencyGate.new(1)
    attempts = 0
    gate_free_during_sleep = false
    err = Rubik::LLM::ClientError.new("HTTP Request failed with code 500: Server Error")

    on_retry = lambda do |_att, _max, _delay, _err|
      # In another thread, check if gate is available while sleeping
      t = Thread.new { gate.synchronize { gate_free_during_sleep = true } }
      t.join(0.05)
    end

    res.retry_transient(gate: gate, max_retries: 1, backoff_base: 0.02, on_retry: on_retry) do
      attempts += 1
      raise err if attempts == 1

      "gate_released_ok"
    end

    assert_equal 2, attempts
    assert gate_free_during_sleep, "ConcurrencyGate must be released during retry backoff"
  end

  def test_subagent_transparently_recovers_from_transient_500_error
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: @config)
    flaky = FlakyProvider.new(
      errors_to_raise: [Rubik::LLM::ClientError.new("HTTP Request failed with code 500: engine-core error")],
      final_response: MockResponse.new("Done after glitch", [])
    )

    inst = sup.spawn(role: "worker", prompt: "do task", provider: flaky)
    sup.wait_for([inst.id], timeout: 5)

    assert_equal :completed, inst.state
    assert_equal 2, flaky.calls
    assert_equal "Done after glitch", inst.result
    sup.shutdown_all
  end

  def test_persistent_network_error_pauses_subagent_preserving_context_and_can_be_resumed
    event_bus = Rubik::EventBus.new
    paused_events = []
    event_bus.subscribe(:subagent_error_paused) { |payload| paused_events << payload }

    sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, config: @config, event_bus: event_bus
    )
    persistent_err = Rubik::LLM::ClientError.new("HTTP Request failed with code 500: engine-core error")
    flaky = FlakyProvider.new(errors_to_raise: [persistent_err, persistent_err, persistent_err])

    inst = sup.spawn(role: "worker", prompt: "do task", provider: flaky)

    # Wait until it enters paused_error
    deadline = Time.now + 3
    sleep 0.05 while inst.state == :running && Time.now < deadline

    assert_equal :paused_error, inst.state
    assert_equal 1, paused_events.size
    assert_equal inst.id, paused_events.first[:id]
    assert_includes inst.last_error, "HTTP Request failed with code 500"
    refute inst.context.disposed?, "Sub-context must NOT be disposed when paused on error"

    # Status shows guidance
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)
    status_json = JSON.parse(tool.execute(action: "status", conversation_id: inst.id))
    assert_equal "paused_error", status_json["state"]
    assert_includes status_json["guidance"], "Subagent paused on provider/network error"

    # Resume the subagent
    resume_res = tool.execute(action: "resume", conversation_id: inst.id)
    assert_includes resume_res, "successfully resumed"

    # Wait for completion
    sup.wait_for([inst.id], timeout: 3)
    assert_equal :completed, inst.state
    assert_equal "Success after recovery", inst.result
    sup.shutdown_all
  end

  def test_resume_all_resumes_multiple_paused_subagents
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: @config)
    persistent_err = Rubik::LLM::ClientError.new("Net::ReadTimeout with #<TCPSocket:(closed)>")

    flaky1 = FlakyProvider.new(errors_to_raise: [persistent_err, persistent_err, persistent_err])
    flaky2 = FlakyProvider.new(errors_to_raise: [persistent_err, persistent_err, persistent_err])

    inst1 = sup.spawn(role: "sub1", prompt: "task 1", provider: flaky1)
    inst2 = sup.spawn(role: "sub2", prompt: "task 2", provider: flaky2)

    sleep 0.05 while inst1.state == :running || inst2.state == :running

    assert_equal :paused_error, inst1.state
    assert_equal :paused_error, inst2.state

    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)
    resume_res = tool.execute(action: "resume")
    assert_includes resume_res, "Resumed subagent(s): #{inst1.id}, #{inst2.id}"

    sup.wait_for([inst1.id, inst2.id], timeout: 3)
    assert_equal :completed, inst1.state
    assert_equal :completed, inst2.state
    sup.shutdown_all
  end

  def test_non_transient_error_fails_immediately_without_pause
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: @config)
    fatal_err = Rubik::LLM::ClientError.new("HTTP 401 Unauthorized: Invalid API key")
    fatal_provider = FlakyProvider.new(errors_to_raise: [fatal_err])

    inst = sup.spawn(role: "fatal_worker", prompt: "do task", provider: fatal_provider)
    sup.wait_for([inst.id], timeout: 2)

    assert_equal :failed, inst.state
    assert_includes inst.last_error, "HTTP 401 Unauthorized"
    sup.shutdown_all
  end

  def test_paused_error_transitions_to_failed_when_timeout_expires
    @config.set("subagents.error_wait_timeout", 0.05)
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: @config)
    persistent_err = Rubik::LLM::ClientError.new("HTTP Request failed with code 503: Service Unavailable")
    flaky = FlakyProvider.new(errors_to_raise: [persistent_err, persistent_err, persistent_err])

    inst = sup.spawn(role: "worker", prompt: "task", provider: flaky)
    # Wait longer than error_wait_timeout (0.05s)
    sleep 0.3

    assert_equal :failed, inst.state
    assert_includes inst.result, "Subagent halted after"
    sup.shutdown_all
  end
end
