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

  def test_defaults_configuration_matches_budget_constant
    budget_default = Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS
    cfg = Rubik::Config::Defaults::DEFAULT_CONFIG["subagents"]
    # The config layer cannot require the orchestrator (layering), so this
    # pin is the weld: change one without the other and this fails.
    assert_equal budget_default, cfg["default_max_steps"]
    assert_equal 2, cfg["provider_concurrency"]
    assert_equal 180, cfg["budget_wait_timeout"]
  end

  def test_supervisor_scale_fallbacks
    supervisor = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context)
    assert_equal Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS, supervisor.default_max_steps
    assert_equal 2, supervisor.provider_gate.capacity
    supervisor.shutdown_all
  end

  def test_invoke_subagent_schema_documents_effective_default_steps
    bare = Rubik::Tools::InvokeSubagentTool.new(runtime_context: @root_context)
    props = bare.params_schema[:properties]
    constant = Rubik::Orchestrator::Subagent::Budget::DEFAULT_MAX_STEPS.to_s

    assert_includes props[:max_steps][:description], "(default: #{constant})"
    batch_desc = props[:subagents][:items][:properties][:max_steps][:description]
    assert_includes batch_desc, "(default: #{constant})"

    # Operator override: the schema must teach what spawns will actually get.
    cfg = Rubik::Config.new
    cfg.set("subagents.default_max_steps", 42)
    sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, config: cfg)
    wired = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)
    wired_props = wired.params_schema[:properties]

    assert_includes wired_props[:max_steps][:description], "(default: 42)"
    refute_includes wired_props[:max_steps][:description], "88"
    sup.shutdown_all
  end
end
