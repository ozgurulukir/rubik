# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentBudgetScale < Minitest::Test
  def setup
    @root_context = Rubik::Runtime::Context.new
  end

  def teardown
    @root_context.dispose unless @root_context.disposed?
  end

  def test_budget_scale_constants
    assert_equal 88, Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS
    assert_equal 20, Rubik::Orchestrator::Subagent::Budget::DEFAULT_GRANT_STEPS
  end

  def test_defaults_configuration_scale
    cfg = Rubik::Config::Defaults::DEFAULT_CONFIG["subagents"]
    assert_equal 88, cfg["default_max_steps"]
    assert_equal 2, cfg["provider_concurrency"]
    assert_equal 180, cfg["budget_wait_timeout"]
  end

  def test_supervisor_scale_fallbacks
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context)
    assert_equal 88, supervisor.default_max_steps
    assert_equal 2, supervisor.provider_gate.capacity
    supervisor.shutdown_all
  end

  def test_invoke_subagent_schema_documents_default_eighty_eight
    tool = Rubik::Tools::InvokeSubagentTool.new(runtime_context: @root_context)
    props = tool.params_schema[:properties]

    single_desc = props[:max_steps][:description]
    assert_includes single_desc, "88"

    batch_desc = props[:subagents][:items][:properties][:max_steps][:description]
    assert_includes batch_desc, "88"
  end
end
