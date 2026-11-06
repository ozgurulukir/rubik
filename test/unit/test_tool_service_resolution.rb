# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/base"
require_relative "../../lib/rubik/runtime/context"
require_relative "../../lib/rubik/coeffects"

class TestToolServiceResolution < Minitest::Test
  class DummyTool < Rubik::Tools::BaseTool
    attr_accessor :runtime_context, :task_manager, :dmesg

    def initialize(runtime_context: nil, task_manager: nil, dmesg: nil)
      super(name: "dummy_tool", description: "dummy", risk: :read, params_schema: {})
      @runtime_context = runtime_context
      @task_manager = task_manager
      @dmesg = dmesg
    end
  end

  def setup
    @ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @ctx&.dispose
  end

  def test_service_resolves_from_runtime_context_via_coeffects_slot
    fake_mgr = Object.new
    @ctx.provide(Rubik::Coeffects::TASK_MANAGER, fake_mgr)

    tool = DummyTool.new(runtime_context: @ctx)
    assert_same fake_mgr, tool.service(:task_manager)
  end

  def test_service_falls_back_to_ivar_when_context_empty
    fallback_mgr = Object.new
    tool = DummyTool.new(runtime_context: @ctx, task_manager: fallback_mgr)

    assert_same fallback_mgr, tool.service(:task_manager)
  end

  def test_service_runtime_context_takes_precedence_over_ivar
    context_mgr = Object.new
    ivar_mgr = Object.new
    @ctx.provide(Rubik::Coeffects::TASK_MANAGER, context_mgr)

    tool = DummyTool.new(runtime_context: @ctx, task_manager: ivar_mgr)
    assert_same context_mgr, tool.service(:task_manager)
  end

  def test_service_resolves_non_services_coeffect_keys
    fake_asker = Object.new
    @ctx.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, fake_asker)

    tool = DummyTool.new(runtime_context: @ctx)
    assert_same fake_asker, tool.service(:subagent_question_asker)
  end

  def test_service_explicit_fallback_arg
    fallback = Object.new
    tool = DummyTool.new(runtime_context: @ctx)

    assert_same fallback, tool.service(:task_manager, fallback)
  end

  def test_service_resolves_via_runtime_manager_context
    fake_mgr = Object.new
    @ctx.provide(Rubik::Coeffects::TASK_MANAGER, fake_mgr)

    rt_manager = Struct.new(:context).new(@ctx)
    tool = DummyTool.new
    tool.instance_variable_set(:@runtime_manager, rt_manager)

    assert_same fake_mgr, tool.service(:task_manager)
  end

  def test_service_with_explicit_ctx_keyword_override
    custom_ctx = Rubik::Runtime::Context.new
    fake_dmesg = Object.new
    custom_ctx.provide(Rubik::Coeffects::DMESG, fake_dmesg)

    tool = DummyTool.new(runtime_context: @ctx)
    assert_same fake_dmesg, tool.service(:dmesg, ctx: custom_ctx)
  ensure
    custom_ctx&.dispose
  end

  def test_service_with_strict_mock_fallback_does_not_invoke_nil_or_equal_on_mock
    # Strict mock that only permits :expected_call; calling .nil? or .equal? raises NoMethodError
    mock = Minitest::Mock.new
    tool = DummyTool.new(runtime_context: @ctx)

    resolved = tool.service(:ast_graph, mock)
    assert_equal mock.__id__, resolved.__id__
  end

  def test_service_preserves_boolean_false_fallback
    tool = DummyTool.new(runtime_context: @ctx)
    assert_equal false, tool.service(:some_flag, false)
  end
end
