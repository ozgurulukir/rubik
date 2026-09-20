# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestOrchestratorFiberLifecycle < Minitest::Test
  class MockProvider < Rubik::LLM::BaseProvider
    attr_reader :calls

    def initialize(responses = [])
      super()
      @responses = responses.dup
      @calls = []
    end

    def complete(messages, opts = {})
      @calls << { messages: messages, opts: opts }
      text = @responses.shift || '{"tool": "finish", "args": { "message": "done" }}'
      Rubik::LLM::Response.new(text: text)
    end
  end

  def setup
    @output = StringIO.new
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: Dir.pwd)
    @tool_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @manager.dispose! unless @ctx.disposed?
  end

  def test_fiber_remains_pending_when_llm_client_is_missing
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)

    fiber = Rubik::Runtime::LoopService.register(@manager)

    assert_equal :pending, fiber.state
    assert_nil fiber.instance
    refute fiber.satisfiable?(@ctx)
  end

  def test_fiber_activates_when_all_coeffects_are_satisfied
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)

    fiber = Rubik::Runtime::LoopService.register(@manager)
    assert_equal :pending, fiber.state

    provider = MockProvider.new
    @manager.provide(:llm_client, provider)

    assert_equal :active, fiber.state
    assert_instance_of Rubik::Orchestrator::Loop, fiber.instance
    assert_equal provider, fiber.instance.instance_variable_get(:@provider)
  end

  def test_zero_downtime_hot_swapping_on_provider_change
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)

    Rubik::Runtime::LoopService.register(@manager)

    provider1 = MockProvider.new
    @manager.provide(:llm_client, provider1)

    fiber = @manager.fibers["orchestrator_loop"]
    assert_equal :active, fiber.state
    first_instance = fiber.instance
    assert_equal provider1, first_instance.instance_variable_get(:@provider)

    # Hot swap provider with provider2
    provider2 = MockProvider.new
    @manager.provide(:llm_client, provider2)

    assert_equal :active, fiber.state
    second_instance = fiber.instance
    refute_equal first_instance.object_id, second_instance.object_id, "Instance should be replaced on hot swap"
    assert_equal provider2, second_instance.instance_variable_get(:@provider)
  end

  def test_atomic_rollback_on_fiber_activation_failure
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)

    inverses_run = []

    fiber = Rubik::Runtime::Fiber.new(name: "failing_loop", inject: ["buffer_manager", "tool_registry", "llm_client"]) do |sub_ctx, _cfg|
      sub_ctx.on_dispose { inverses_run << "inverse_1" }
      sub_ctx.on_dispose { inverses_run << "inverse_2" }
      raise "Intentional crash during loop fiber activation!"
    end

    @manager.register_fiber(fiber)
    assert_equal :pending, fiber.state

    provider = MockProvider.new
    @manager.provide(:llm_client, provider)

    assert_equal :failed, fiber.state
    assert_nil fiber.instance
    assert_equal "Intentional crash during loop fiber activation!", fiber.last_error.message
    assert_equal ["inverse_2", "inverse_1"], inverses_run, "Inverses must be executed in LIFO order upon failure rollback"
  end

  def test_shell_reactive_orchestrator_loop_integration
    shell = Rubik::REPL::Shell.new(output: @output)
    begin
      fiber = shell.runtime_manager.fibers["orchestrator_loop"]
      assert fiber, "orchestrator_loop fiber should be registered in Shell"

      # Initially active or pending depending on default router config
      mock_provider = MockProvider.new(['{"tool": "finish", "args": { "message": "task completed" }}'])
      shell.runtime_manager.provide(:llm_client, mock_provider)
      shell.runtime_manager.provide(:llm, mock_provider)

      assert_equal :active, fiber.state
      active_loop = shell.orchestrator_loop
      assert_instance_of Rubik::Orchestrator::Loop, active_loop
      assert_equal fiber.instance, active_loop

      # Custom opts produces customized loop
      custom_loop = shell.orchestrator_loop(max_steps: 10, model: "custom-model")
      assert_instance_of Rubik::Orchestrator::Loop, custom_loop
      assert_equal 10, custom_loop.max_steps
      assert_equal "custom-model", custom_loop.instance_variable_get(:@model)
    ensure
      shell.stop
    end
  end

  def test_repl_commands_trigger_runtime_provider_hot_swap
    shell = Rubik::REPL::Shell.new(output: @output)
    begin
      fiber = shell.runtime_manager.fibers["orchestrator_loop"]
      assert fiber

      # Add a mock provider through REPL !provider command
      shell.execute_input("!provider add test_prov openai_compatible http://localhost:11434/v1 --key=dummy --model=test-model-v1")
      assert_includes @output.string, "Successfully added provider 'test_prov'"

      # Switch default model to test_prov/test-model-v1
      shell.execute_input("!model set default test_prov/test-model-v1")
      assert_includes @output.string, "Set model role 'default' to test_prov/test-model-v1"

      # Verify runtime_manager coeffect context was updated
      llm_client = shell.runtime_manager.context.get(:llm_client)
      assert llm_client, "llm_client coeffect must be provided in context"
      assert_equal :active, fiber.state
    ensure
      shell.stop
    end
  end

  def test_fiber_execution_with_mock_provider
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)
    provider = MockProvider.new(['{"tool": "finish", "args": { "message": "fiber execution ok" }}'])
    @manager.provide(:llm_client, provider)

    fiber = Rubik::Runtime::LoopService.register(@manager)
    assert_equal :active, fiber.state
    loop_inst = fiber.instance

    res = loop_inst.run("Perform fiber test")
    assert res[:ok]
    assert_equal "fiber execution ok", res[:output]
  end

  # =========================================================================
  # 10. unprovide retracts the gated fiber + its inverse (AGENTS.md §5, Finding B)
  # =========================================================================

  # A service retracted via Manager#unprovide must NOT leave an orphan fiber
  # gated on that coeffect still Active against a now-stale context. The fiber
  # gated on the coeffect must be retracted (Active->Pending) and its partial
  # inverse must run (LIFO). Previously unprovide dropped the service without
  # touching the fiber -> orphan fiber running against a disposed context.
  def test_unprovide_retracts_gated_fiber_and_runs_inverse
    retract_flag = []
    @manager.provide(:coeffect_key, retract_flag)

    # Fiber factory injects the coeffect; its factory body registers an inverse
    # that clears the flag. When unprovide retracts the fiber, that inverse runs.
    # activate! always invokes the factory as (sub_context, config); the coeffect
    # value is surfaced through the sub-context so the factory can grab it there.
    @manager.register_component(:gate_fiber, inject: [:coeffect_key]) do |sub_context, _config|
      coeffect_key = sub_context.get(:coeffect_key)
      coeffect_key << :fiber_active
      begin
        :running
      ensure
        # This ensure is the fiber's inverse: it must run on retraction.
        coeffect_key.delete(:fiber_active)
        retract_flag << :inverse
      end
    end

    fiber = @manager.fibers["gate_fiber"]
    assert_equal :active, fiber.state, "fiber gated on coeffect_key must be Active after provide"

    @manager.unprovide(:coeffect_key)

    refute_includes retract_flag, :fiber_active, "fiber no longer Active against a stale context"
    assert_includes retract_flag, :inverse, "the fiber's inverse must run on retraction (no orphan)"
    refute_equal :active, @manager.fibers["gate_fiber"].state,
      "gated fiber must transition Active->Pending (retracted), not left running"
  end

  def test_unprovide_returns_nil_for_unknown_key
    # idempotent: unproviding a key that is not present is a no-op
    assert_nil @manager.unprovide(:never_provided)
  end
end
