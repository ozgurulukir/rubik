# frozen_string_literal: true

require_relative "../test_helper"

class TestSubagentAdmissionPolicy < Minitest::Test
  def setup
    @type_registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
    @root_ctx = Rubik::Runtime::Context.new
  end

  def teardown
    @root_ctx&.dispose unless @root_ctx&.disposed?
  end

  # =========================================================================
  # Seam helpers (behavior asserted through ScopedRegistry / ProfileContract /
  # ContextBuilder — no ivar poking)
  # =========================================================================

  def build_scoped(type_name, source_registry)
    child_ctx = @root_ctx.extend
    scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_registry,
      type_def: @type_registry.get(type_name),
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )
    [scoped, child_ctx]
  ensure
    child_ctx&.dispose
  end

  def source_with_mcp_and_unknown
    source = Rubik::Tools::Registry.new
    { "mcp_read_tool" => :read, "mcp_write_tool" => :write, "mcp_exec_tool" => :execute }.each do |name, risk|
      source.register(Rubik::Tools::BaseTool.new(name: name, description: "mcp proxy", risk: risk), origin: :mcp)
    end
    # A dynamic tool with no #risk reader at all: the idiom's unknown branch.
    source.register(Struct.new(:name).new("synth_unknown_tool"), origin: :synthesis)
    source
  end

  def admitted_names(type_name, source_registry)
    scoped, = build_scoped(type_name, source_registry)
    scoped.list.map(&:name)
  end

  def define_custom(name, grants:)
    @type_registry.define_custom(
      name: name, description: "policy probe #{name}", system_prompt: "Probe.",
      grants: grants, context: @root_ctx
    )
  end

  # =========================================================================
  # 1. MCP origin is risk-gated on the custom plane
  # =========================================================================

  def test_mcp_read_risk_is_admitted_to_zero_grant_customs
    source = source_with_mcp_and_unknown
    define_custom("probe_ro", grants: [])

    names = admitted_names("probe_ro", source)

    assert_includes names, "mcp_read_tool", "read-only MCP tools stay available to read-only customs"
    refute_includes names, "mcp_write_tool"
    refute_includes names, "mcp_exec_tool"
    refute_includes names, "synth_unknown_tool", "unknown risk must fail closed even at read level"
  end

  def test_mcp_write_and_execute_risk_require_the_write_grant
    source = source_with_mcp_and_unknown
    define_custom("probe_rw", grants: ["write"])

    names = admitted_names("probe_rw", source)

    assert_includes names, "mcp_read_tool"
    assert_includes names, "mcp_write_tool", "the write grant elevates MCP write-risk tools"
    assert_includes names, "mcp_exec_tool", "the write grant elevates MCP execute-risk tools"
    refute_includes names, "synth_unknown_tool", "no grant admits unknown risk"
  end

  def test_mcp_execute_risk_stays_out_of_grantless_customs
    source = Rubik::Tools::Registry.new
    source.register(Rubik::Tools::BaseTool.new(name: "mcp_destructive_tool", description: "d", risk: :execute),
                    origin: :mcp)
    define_custom("auditor", grants: [])

    refute_includes admitted_names("auditor", source), "mcp_destructive_tool",
                    "a destructiveHint MCP tool must not sit in a plane labeled read-only"
  end

  # =========================================================================
  # 2. Unknown risk fails closed everywhere (customs + self + archetypes)
  # =========================================================================

  def test_unknown_risk_is_rejected_from_customs_even_with_the_write_grant
    source = source_with_mcp_and_unknown
    define_custom("builder", grants: ["write"])

    refute_includes admitted_names("builder", source), "synth_unknown_tool"
  end

  def test_unknown_risk_is_rejected_from_the_self_plane
    source = source_with_mcp_and_unknown

    refute_includes admitted_names("self", source), "synth_unknown_tool",
                    "the full-clone plane must not fall back to :execute for unreadable risk"
  end

  def test_unknown_risk_is_rejected_from_research_and_coder
    source = source_with_mcp_and_unknown

    ["research", "coder"].each do |type_name|
      refute_includes admitted_names(type_name, source), "synth_unknown_tool", type_name
    end
  end

  # =========================================================================
  # 3. Per-plane MCP contracts
  # =========================================================================

  def test_research_and_coder_reject_every_mcp_origin_tool
    source = source_with_mcp_and_unknown

    ["research", "coder"].each do |type_name|
      names = admitted_names(type_name, source)
      refute_includes names, "mcp_read_tool", "#{type_name} must not admit MCP tools (explicit policy)"
      refute_includes names, "mcp_write_tool", type_name
      refute_includes names, "mcp_exec_tool", type_name
    end
  end

  def test_self_plane_keeps_its_all_mcp_contract
    source = source_with_mcp_and_unknown

    names = admitted_names("self", source)

    assert_includes names, "mcp_read_tool", "the full-clone contract admits all MCP tools"
    assert_includes names, "mcp_write_tool"
    assert_includes names, "mcp_exec_tool"
  end

  def test_dynamic_read_risk_still_reaches_research_coder_and_customs
    source = Rubik::Tools::Registry.new
    source.register(Rubik::Tools::BaseTool.new(name: "overlay_read_tool", description: "d", risk: :read),
                    origin: :overlay)
    define_custom("probe_ro", grants: [])

    ["research", "coder", "probe_ro"].each do |type_name|
      assert_includes admitted_names(type_name, source), "overlay_read_tool",
                      "#{type_name} must keep admitting read-risk overlay tools"
    end
  end

  # =========================================================================
  # 4. Capability labels derive from the same policy
  # =========================================================================

  def test_builtin_label_matrix_matches_the_prompt_pins
    xml = Rubik::Prompt::ContextBuilder.build_subagents_xml(@type_registry)

    assert_includes xml, '<subagent name="research" tools="read_only" default_workspace="inherit">'
    assert_includes xml, '<subagent name="coder" tools="read_write_test" default_workspace="branch">'
    assert_includes xml, '<subagent name="self" tools="full_clone" default_workspace="inherit">'
    assert_includes xml, '<subagent name="vakanuvis" tools="read_write_test" default_workspace="inherit">'
    assert_includes xml, '<subagent name="pruner" tools="read_only" default_workspace="inherit">'
  end

  def test_capability_label_agrees_with_the_xml_per_builtin
    {
      "research" => "read_only", "coder" => "read_write_test", "self" => "full_clone",
      "vakanuvis" => "read_write_test", "pruner" => "read_only"
    }.each do |name, expected|
      assert_equal expected, Rubik::Orchestrator::Subagent::AdmissionPolicy.capability_label(@type_registry.get(name)), name
    end
  end

  def test_zero_grant_customs_hold_execute_class_tools_and_label_read_execute
    define_custom("executor", grants: [])
    xml = Rubik::Prompt::ContextBuilder.build_subagents_xml(@type_registry)

    assert_includes xml, '<subagent name="executor" tools="read_execute" default_workspace="inherit">',
                    "zero-grant customs run tests/commands, so read_only would be a dishonest label"
  end

  def test_write_granted_customs_label_read_write_test
    define_custom("builder", grants: ["write"])
    xml = Rubik::Prompt::ContextBuilder.build_subagents_xml(@type_registry)

    assert_includes xml, '<subagent name="builder" tools="read_write_test" default_workspace="inherit">'
  end

  # =========================================================================
  # 5. Single-sourced vocabulary
  # =========================================================================

  def test_policy_constants_are_the_single_vocabulary_home
    policy = Rubik::Orchestrator::Subagent::AdmissionPolicy

    assert_equal [:synthesis, :overlay], policy::DYNAMIC_ORIGINS
    assert policy::DYNAMIC_ORIGINS.frozen?
    assert_equal :mcp, policy::MCP
    assert_equal [:read, :write, :execute], policy::RISK_LADDER
    assert policy::RISK_LADDER.frozen?
  end

  def test_no_subagent_module_restates_the_dynamic_origin_vocabulary
    restatements = Dir[File.expand_path("../../lib/rubik/orchestrator/subagent/*.rb", __dir__)].each_with_object([]) do |path, found|
      next if File.basename(path) == "admission_policy.rb"

      File.readlines(path).each_with_index do |line, index|
        found << "#{File.basename(path)}:#{index + 1}" if line.match?(/:synthesis|:overlay/)
      end
    end

    assert_empty restatements, "the origin vocabulary must come from AdmissionPolicy::DYNAMIC_ORIGINS only: #{restatements.join(', ')}"
  end

  # =========================================================================
  # 6. ProfileContract.tool_filter stays the public grants-formula seam
  # =========================================================================

  def test_profile_contract_tool_filter_delegates_to_the_grants_formula
    contract = Rubik::Orchestrator::Subagent::ProfileContract

    refute contract.tool_filter([]).call("write_file")
    refute contract.tool_filter([]).call("invoke_subagent")
    assert contract.tool_filter([]).call("read_file")

    assert contract.tool_filter(["write"]).call("write_file")
    refute contract.tool_filter(["write"]).call("invoke_subagent")

    assert contract.tool_filter(["subagent_spawn"]).call("invoke_subagent")
    refute contract.tool_filter(["subagent_spawn"]).call("write_file")
  end

  # =========================================================================
  # 7. Root-only tools never cross any plane, policy-side
  # =========================================================================

  def test_policy_rejects_root_only_tools_before_any_plane_rule
    policy = Rubik::Orchestrator::Subagent::AdmissionPolicy
    tool = Rubik::Tools::BaseTool.new(name: "vakanuvis", description: "chronicler", risk: :write)

    planes = [:research, :coder, :self]
    planes.each do |plane|
      refute policy.allowed?("vakanuvis", tool, :builtin, plane: plane), plane
    end
    refute policy.allowed?("vakanuvis", tool, :builtin, plane: @type_registry.get("self")), "type_def plane"
  end

  # =========================================================================
  # 8. Loud failure at the plane boundary (no silent all-tools grant)
  # =========================================================================

  def test_nil_tool_filter_is_rejected_loudly_at_the_plane_boundary
    source = Rubik::Tools::Registry.new
    source.register(Rubik::Tools::BaseTool.new(name: "mcp_read_tool", description: "d", risk: :read), origin: :mcp)
    naked = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "no_filter", description: "Filter-less type", system_prompt: "Probe.",
      custom_prompt: true, context: @root_ctx
    )

    error = assert_raises(ArgumentError) do
      Rubik::Orchestrator::Subagent::ScopedRegistry.build(
        source_registry: source, type_def: naked, child_ctx: nil, buffer: nil, parent_buffer: nil
      )
    end

    assert_includes error.message, "no_filter"
    assert_includes error.message, "no tool_filter"
  end

  def test_registry_rejects_multi_required_arg_tool_filters_at_registration
    odd = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "odd_arity", description: "Confused filter shape", system_prompt: "Probe.",
      custom_prompt: true, tool_filter: ->(_name, _tool, _origin) { true }, context: @root_ctx
    )

    error = assert_raises(ArgumentError) { @type_registry.register(odd) }

    assert_includes error.message, "odd_arity"
    assert_includes error.message, "tool_filter"
  end

  def test_registry_accepts_optional_arg_admission_lambdas_and_name_filters
    optional = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "optional_arity", description: "Optional-arg lambda", system_prompt: "Probe.",
      custom_prompt: true, tool_filter: ->(_name, _tool = nil, _origin = nil) { true }, context: @root_ctx
    )
    assert @type_registry.register(optional), "optional-arg lambdas are a supported filter shape"

    named = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "name_filter", description: "Name filter", system_prompt: "Probe.",
      custom_prompt: true, tool_filter: ->(name) { name == "read_file" }, context: @root_ctx
    )
    assert @type_registry.register(named), "1-arg name filters are a supported filter shape"
  end

  # =========================================================================
  # 9. Unrecognized origins are ladder-gated, never default-allowed
  # =========================================================================

  def test_unrecognized_origin_with_unreadable_risk_is_rejected_from_self_and_custom
    source = Rubik::Tools::Registry.new
    source.register(Struct.new(:name).new("future_origin_unknown_tool"), origin: :future_origin)
    define_custom("probe_ro", grants: [])

    refute_includes admitted_names("self", source), "future_origin_unknown_tool",
                    "a future origin must not bypass the risk ladder on the full-clone plane"
    refute_includes admitted_names("probe_ro", source), "future_origin_unknown_tool",
                    "a future origin must not bypass the risk ladder on the custom plane"
  end

  def test_unrecognized_origin_read_risk_is_admitted_per_ladder_rules
    source = Rubik::Tools::Registry.new
    source.register(Rubik::Tools::BaseTool.new(name: "future_origin_read_tool", description: "d", risk: :read),
                    origin: :future_origin)
    source.register(Rubik::Tools::BaseTool.new(name: "future_origin_write_tool", description: "d", risk: :write),
                    origin: :future_origin)
    define_custom("probe_ro", grants: [])

    assert_includes admitted_names("self", source), "future_origin_read_tool"
    assert_includes admitted_names("self", source), "future_origin_write_tool",
                    "the full-clone ladder admits write risk without a grant"
    assert_includes admitted_names("probe_ro", source), "future_origin_read_tool"
    refute_includes admitted_names("probe_ro", source), "future_origin_write_tool",
                    "grantless customs admit only read risk from unrecognized origins"
  end
end
