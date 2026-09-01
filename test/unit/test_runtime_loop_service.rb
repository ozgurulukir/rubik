# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestRuntimeLoopService < Minitest::Test
  def setup
    @ctx = Rubik::Runtime::Context.new
    @manager = Rubik::Runtime::Manager.new(@ctx)
    @temp_dir = Dir.mktmpdir("loop_service_test")

    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @tool_registry = Rubik::Tools::Registry.new
    @tool_registry.register(Rubik::Tools::FinishTool.new)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
    @ctx.dispose unless @ctx.disposed?
  end

  def create_mock_provider
    Class.new(Rubik::LLM::BaseProvider) do
      def complete(_messages, _opts = {})
        Rubik::LLM::Response.new(
          text: '{"tool": "finish", "args": { "message": "done" }}',
          tool_calls: [{ "tool" => "finish", "args" => { "message" => "done" } }]
        )
      end
    end.new
  end

  # ── register ───────────────────────────────────────────────────────

  def test_registers_fiber_in_pending_state_without_coeffects
    fiber = Rubik::Runtime::LoopService.register(@manager, shell: nil)

    assert_equal :pending, fiber.state
    assert_nil fiber.instance
    assert_instance_of Rubik::Runtime::AgentLoopFiber, fiber
    assert_equal "orchestrator_loop", fiber.name
    assert @manager.fibers.key?("orchestrator_loop")
  end

  def test_fiber_activates_when_all_coeffects_available
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)
    mock_provider = create_mock_provider

    fiber = Rubik::Runtime::LoopService.register(@manager, shell: nil)
    assert_equal :pending, fiber.state

    @manager.provide(:llm_client, mock_provider)

    assert_equal :active, fiber.state
    assert_instance_of Rubik::Orchestrator::Loop, fiber.instance
  end

  def test_register_with_custom_name_and_inject
    fiber = Rubik::Runtime::LoopService.register(
      @manager,
      name: "custom_loop",
      inject: ["buffer_manager"],
      shell: nil
    )

    assert_equal "custom_loop", fiber.name
    assert_equal ["buffer_manager"], fiber.inject
  end

  def test_register_into_raw_context
    fiber = Rubik::Runtime::LoopService.register(@ctx, shell: nil)

    assert_equal :pending, fiber.state
    refute_respond_to @ctx, :fibers
  end

  # ── build_loop ─────────────────────────────────────────────────────

  def test_build_loop_creates_orchestrator_loop_with_defaults
    provider = create_mock_provider
    @ctx.provide("llm_client", provider)
    @ctx.provide("tool_registry", @tool_registry)
    @ctx.provide("buffer_manager", @buffer_manager)

    loop_inst = Rubik::Runtime::LoopService.build_loop(@ctx)

    assert_instance_of Rubik::Orchestrator::Loop, loop_inst
    assert_equal 40, loop_inst.max_steps
    assert_equal provider, loop_inst.provider
  end

  def test_build_loop_respects_custom_config
    provider = create_mock_provider
    @ctx.provide("llm_client", provider)
    @ctx.provide("tool_registry", @tool_registry)
    @ctx.provide("buffer_manager", @buffer_manager)

    loop_inst = Rubik::Runtime::LoopService.build_loop(
      @ctx,
      config: {
        provider: provider,
        tool_registry: @tool_registry,
        max_steps: 10,
        warn_at_ratio: 0.5,
        model: "test-model",
        context_limit: 16_384,
        max_output_tokens: 2_048
      }
    )

    assert_equal 10, loop_inst.max_steps
    assert_equal "test-model", loop_inst.model
    assert_equal 16_384, loop_inst.context_limit
    assert_equal 2_048, loop_inst.max_output_tokens
  end

  def test_build_loop_resolves_provider_from_context
    provider = create_mock_provider
    @ctx.provide("llm_client", provider)
    @ctx.provide("tool_registry", @tool_registry)
    @ctx.provide("buffer_manager", @buffer_manager)

    loop_inst = Rubik::Runtime::LoopService.build_loop(@ctx)

    assert_equal provider, loop_inst.provider
    assert_instance_of Rubik::Orchestrator::Loop, loop_inst
  end

  def test_build_loop_with_nil_provider_does_not_crash
    loop_inst = Rubik::Runtime::LoopService.build_loop(@ctx)

    assert_instance_of Rubik::Orchestrator::Loop, loop_inst
  end

  # ── AgentLoopFiber ─────────────────────────────────────────────────

  def test_agent_loop_fiber_builds_loop_instance
    provider = create_mock_provider

    fiber = Rubik::Runtime::AgentLoopFiber.new(
      name: "test_loop",
      inject: ["llm_client", "tool_registry", "buffer_manager"],
      shell: nil
    )

    @ctx.provide("llm_client", provider)
    @ctx.provide("tool_registry", @tool_registry)
    @ctx.provide("buffer_manager", @buffer_manager)

    assert fiber.satisfiable?(@ctx)
    assert fiber.activate!(@ctx)

    assert_equal :active, fiber.state
    assert_instance_of Rubik::Orchestrator::Loop, fiber.instance
  end

  def test_agent_loop_fiber_activation_requires_coeffects
    fiber = Rubik::Runtime::AgentLoopFiber.new(
      name: "missing_deps",
      inject: ["llm_client", "tool_registry", "buffer_manager"],
      shell: nil
    )

    refute fiber.satisfiable?(@ctx)
    refute fiber.activate!(@ctx)
    assert_equal :pending, fiber.state
  end

  # ── end-to-end through the manager ─────────────────────────────────

  def test_full_fiber_lifecycle_with_manager
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)
    provider = create_mock_provider

    fiber = Rubik::Runtime::LoopService.register(@manager, shell: nil)
    assert_equal :pending, fiber.state

    @manager.provide(:llm_client, provider)
    assert_equal :active, fiber.state

    res = fiber.instance.run("Run a task")
    assert res[:ok]
    assert_equal "done", res[:output]
  end

  def test_hot_swap_rebuilds_loop_with_new_provider
    @manager.provide(:buffer_manager, @buffer_manager)
    @manager.provide(:tool_registry, @tool_registry)

    fiber = Rubik::Runtime::LoopService.register(@manager, shell: nil)
    provider1 = create_mock_provider
    @manager.provide(:llm_client, provider1)

    assert_equal :active, fiber.state
    first_instance = fiber.instance
    assert_equal provider1, first_instance.provider

    provider2 = create_mock_provider
    @manager.provide(:llm_client, provider2)

    assert_equal :active, fiber.state
    second_instance = fiber.instance
    refute_equal first_instance.object_id, second_instance.object_id
    assert_equal provider2, second_instance.provider
  end
end
