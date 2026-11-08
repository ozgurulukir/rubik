# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/tools/registry"
require_relative "../../lib/rubik/tools/builtins/synthesis"
require_relative "../../lib/rubik/tools/builtins/unsynthesize"
require_relative "../../lib/rubik/tools/preflight_runner"
require_relative "../../lib/rubik/runtime/overlay_storage"
require_relative "../../lib/rubik/runtime/synthesized_tool_context"
require_relative "../../lib/rubik/orchestrator/subagent/scoped_registry"
require_relative "../../lib/rubik/orchestrator/subagent/builtin_types"
require_relative "../../lib/rubik/orchestrator/subagent/type_definition"
require_relative "../../lib/rubik/orchestrator/subagent/profile_contract"
require_relative "../../lib/rubik/runtime/context"

# ==============================================================================
# E2E & Integration Test Suite — Pillar 3: Synthesis Execution, Preflight & Subagent Visibility
# Features 13 - 17 (Tier 1: Feature Coverage & Tier 2: Boundary/Edge Cases)
#
# Specifications:
# - PROJECT.md (Features 13-17)
# - ORIGINAL_REQUEST.md (R3: Synthesis Execution, Preflight & Subagent Visibility)
# - permission_architecture_review.md (§2: Deep Audit & §3: Pillar 3 Refinement)
# ==============================================================================
class TestE2EPermissionsPillar3 < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_pillar3_test")
    @guard = Rubik::Security::Guard.new
    @registry = Rubik::Tools::Registry.new
    @storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp, home_dir: @tmp)
    @runtime_context = Rubik::Runtime::Context.new
    @runtime_manager = Struct.new(:context).new(@runtime_context)
    @tool = Rubik::Tools::SynthesizeToolTool.new(
      @registry, @storage, @guard, runtime_manager: @runtime_manager
    )
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ============================================================================
  # Feature 13: Conditional tool preflight
  # (Only execute preflight in SynthesizeToolTool if test_args is provided)
  # ============================================================================

  def test_f13_synthesis_succeeds_without_test_args_for_tools_with_required_params
    # Tool requires 'divisor' parameter. With unconditional preflight using {},
    # this crashed with ZeroDivisionError or KeyError on {}.
    code = <<~RUBY
      ->(args) do
        divisor = args.fetch("divisor")
        { result: 100 / divisor.to_i }
      end
    RUBY

    res = @tool.execute(
      "name" => "divide_num",
      "description" => "Divides 100 by divisor",
      "code" => code,
      "scope" => "session"
    )

    assert_includes res, "Successfully synthesized",
                    "Synthesizing tool without test_args must not fail on empty {} preflight"
    assert @registry.get("divide_num"), "Tool must be registered in the active toolbelt"
  end

  def test_f13_synthesis_runs_preflight_when_test_args_provided
    code = <<~RUBY
      ->(args) do
        divisor = args.fetch("divisor")
        { result: 100 / divisor.to_i }
      end
    RUBY

    # Valid test_args -> preflight passes and notes verification
    res = @tool.execute(
      "name" => "divide_with_test",
      "description" => "Divides 100 by divisor",
      "code" => code,
      "scope" => "session",
      "test_args" => { "divisor" => 5 }
    )

    assert_includes res, "Successfully synthesized"
    assert_includes res, "Pre-flight verified with provided test_args"

    # Failing test_args -> preflight catches error and rejects tool
    res_fail = @tool.execute(
      "name" => "divide_broken",
      "description" => "Broken division",
      "code" => code,
      "scope" => "session",
      "test_args" => { "divisor" => 0 } # ZeroDivisionError
    )

    assert_includes res_fail, "Pre-flight verification failed"
    refute @registry.get("divide_broken"), "Tool with failing preflight must not be registered"
  end

  # ============================================================================
  # Feature 14: 2-Arity ->(args, ctx) tool support
  # ============================================================================

  def test_f14_supports_2_arity_tool_handler_in_synthesize_tool_tool
    @runtime_context.provide("test_service", "service_value_42")

    code = <<~RUBY
      ->(args, ctx) do
        val = ctx.require("test_service")
        { status: "ok", val: val, input: args["input"] }
      end
    RUBY

    res = @tool.execute(
      "name" => "coeffect_tool",
      "description" => "Tool using runtime coeffect",
      "code" => code,
      "scope" => "session"
    )

    assert_includes res, "Successfully synthesized"
    tool_inst = @registry.get("coeffect_tool")
    assert tool_inst, "Tool must be registered"

    # Executing the tool must pass ctx without ArgumentError
    out = tool_inst.execute("input" => "hello")
    # Verify execution returned expected hash or json
    assert_equal "ok", out[:status] || out["status"]
    assert_equal "service_value_42", out[:val] || out["val"]
  end

  def test_f14_preflight_runner_supports_2_arity_tools
    code = <<~RUBY
      ->(args, ctx) do
        { ok: true, has_ctx: !ctx.nil?, echo: args["echo"] }
      end
    RUBY

    # PreflightRunner.run in :tool mode with 2-arity lambda
    verdict = Rubik::Tools::PreflightRunner.run(
      code,
      { "echo" => "preflight_test" },
      guard: @guard,
      mode: :tool
    )

    assert_nil verdict, "PreflightRunner should succeed for 2-arity tool without ArgumentError"
  end

  # ============================================================================
  # Feature 15: SynthesizeToolTool declaration cleanup
  # ============================================================================

  def test_f15_declaration_does_not_advise_extending_base_tool
    declaration = Rubik::Tools::SynthesizeToolTool::DECLARATION
    desc = declaration.params_schema.dig(:properties, :code, :description) ||
           declaration.params_schema.dig("properties", "code", "description")

    refute_includes desc.to_s, "or class extending Rubik::Tools::BaseTool",
                    "Schema description must not advertise extending BaseTool (which is blocked by Guard)"

    # Error message if code is not callable should not mention BaseTool subclass
    invalid_eval_code = "'just a string'"
    res = @tool.execute("name" => "invalid_tool", "code" => invalid_eval_code, "scope" => "session")
    refute_includes res.to_s, "BaseTool subclass",
                    "Error message should not mislead about BaseTool subclasses"
  end

  # ============================================================================
  # Feature 16: Subagent synthesis tool visibility
  # (Propagate :synthesis and :overlay tools to :research and :coder subagents)
  # ============================================================================

  def test_f16_subagent_tool_visibility_for_research_and_coder
    source_reg = Rubik::Tools::Registry.new

    # 1. Read-only synthesized tool (risk: :read)
    read_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "custom_read_tool", description: "Reads stats", risk: :read, params_schema: {})
      end

      def execute(_args = {})
        { stats: [1, 2, 3] }
      end
    end.new
    source_reg.register(read_tool, origin: :synthesis)

    # 2. Mutating synthesized tool (risk: :write)
    write_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "custom_write_tool", description: "Writes stats", risk: :write, params_schema: {})
      end

      def execute(_args = {})
        { ok: true }
      end
    end.new
    source_reg.register(write_tool, origin: :synthesis)

    # 3. Overlay tool (risk: :execute)
    exec_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "custom_exec_tool", description: "Runs compilation", risk: :execute, params_schema: {})
      end

      def execute(_args = {})
        { compiled: true }
      end
    end.new
    source_reg.register(exec_tool, origin: :overlay)

    # Create subagent definitions
    type_defs = Rubik::Orchestrator::Subagent::BuiltinTypes.default_definitions(
      Rubik::Orchestrator::Subagent::TypeDefinition
    )
    research_def = type_defs.find { |d| d.name == "research" }
    coder_def = type_defs.find { |d| d.name == "coder" }

    child_ctx = Rubik::Runtime::Context.new

    # Build registry for :research
    research_reg = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: research_def,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    # :research should include custom_read_tool (risk: :read)
    assert research_reg.get("custom_read_tool"), ":research subagent must receive synthesized tool with risk: :read"
    # :research should NOT include write or execute tools
    refute research_reg.get("custom_write_tool"), ":research subagent must NOT receive write-risk synthesized tool"
    refute research_reg.get("custom_exec_tool"), ":research subagent must NOT receive execute-risk overlay tool"

    # Build registry for :coder
    coder_reg = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: coder_def,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    # :coder should receive all synthesized and overlay tools
    assert coder_reg.get("custom_read_tool"), ":coder subagent must receive custom_read_tool"
    assert coder_reg.get("custom_write_tool"), ":coder subagent must receive custom_write_tool"
    assert coder_reg.get("custom_exec_tool"), ":coder subagent must receive custom_exec_tool"
  end

  # ============================================================================
  # Feature 17: SynthesizeToolTool#rebind_to
  # ============================================================================

  def test_f17_synthesize_tool_rebind_to_scoped_context
    assert_respond_to @tool, :rebind_to, "SynthesizeToolTool must implement rebind_to(ctx)"

    subagent_reg = Rubik::Tools::Registry.new
    subagent_ctx = Rubik::Runtime::Context.new
    subagent_ctx.provide("tool_registry", subagent_reg)

    rebound_tool = @tool.rebind_to(subagent_ctx)
    refute_same @tool, rebound_tool, "rebind_to must return a new rebound instance"

    # Synthesize tool using rebound instance
    code = '->(args) { { rebound: true } }'
    res = rebound_tool.execute(
      "name" => "subagent_local_tool",
      "description" => "Local subagent tool",
      "code" => code,
      "scope" => "session"
    )

    assert_includes res, "Successfully synthesized"
    # Tool must be present in subagent's registry
    assert subagent_reg.get("subagent_local_tool"),
           "Rebound SynthesizeToolTool must register into the subagent's tool registry"
  end

  # ============================================================================
  # Tier 2: Boundary & Corner Cases for Pillar 3
  # ============================================================================

  def test_tier2_boundary_preflight_timeout_handling
    # A runaway loop in preflight should be caught by timeout
    code = '->(args) { loop { sleep 0.1 } }'

    # With test_args, preflight will attempt to run and time out
    res = @tool.execute(
      "name" => "infinite_loop_tool",
      "description" => "Hanging tool",
      "code" => code,
      "scope" => "session",
      "test_args" => { "x" => 1 }
    )

    assert_includes res, "Pre-flight verification failed"
    assert_includes res, "timed out"
    refute @registry.get("infinite_loop_tool")
  end

  def test_tier2_boundary_rebind_with_unsupported_context
    # Rebinding with a context that lacks tool_registry or is nil should gracefully fail or keep existing
    unsupported_ctx = Object.new
    rebound = @tool.rebind_to(unsupported_ctx)
    assert rebound, "rebind_to should handle unexpected context gracefully"
  end

  # ============================================================================
  # Remediation Tests: Milestone 3 Iteration 2 (Arity, Sealing, Filtering, Rebind)
  # ============================================================================

  def test_remediation_arity_dispatch_default_arguments
    # 1. Lambda with default parameters ->(args = {})
    code_default = <<~RUBY
      ->(args = {}) do
        { ok: true, echo: args["echo"] || "default_val" }
      end
    RUBY

    res = @tool.execute(
      "name" => "default_args_tool",
      "description" => "Tool with default args",
      "code" => code_default,
      "scope" => "session",
      "test_args" => { "echo" => "preflight" }
    )
    assert_includes res, "Successfully synthesized"
    tool_inst = @registry.get("default_args_tool")
    assert tool_inst

    # Execution with empty args and populated args should not raise ArgumentError
    res_empty = tool_inst.execute({})
    assert_equal "default_val", res_empty[:echo]

    res_val = tool_inst.execute("echo" => "custom")
    assert_equal "custom", res_val[:echo]

    # 2. Lambda with 0 arguments -> {}
    code_zero = "-> { { zero_arity: true } }"
    res_zero = @tool.execute(
      "name" => "zero_arg_tool",
      "description" => "Tool with 0 args",
      "code" => code_zero,
      "scope" => "session",
      "test_args" => {}
    )
    assert_includes res_zero, "Successfully synthesized"
    tool_zero = @registry.get("zero_arg_tool")
    assert tool_zero
    assert_equal true, tool_zero.execute({})[:zero_arity]
  end

  def test_remediation_sealed_context_blocks_mutations_and_leaks
    @runtime_context.provide("allowed_service", "service_42")

    code = <<~RUBY
      ->(args, ctx) do
        results = {}

        # 1. Blocked lifecycle methods must raise NoMethodError
        begin
          ctx.dispose
          results[:dispose_blocked] = false
        rescue NoMethodError
          results[:dispose_blocked] = true
        end

        begin
          ctx.provide("malicious", "payload")
          results[:provide_blocked] = false
        rescue NoMethodError
          results[:provide_blocked] = true
        end

        begin
          ctx.unprovide("allowed_service")
          results[:unprovide_blocked] = false
        rescue NoMethodError
          results[:unprovide_blocked] = true
        end

        begin
          ctx.parent
          results[:parent_blocked] = false
        rescue NoMethodError
          results[:parent_blocked] = true
        end

        begin
          ctx.extend
          results[:extend_blocked] = false
        rescue NoMethodError
          results[:extend_blocked] = true
        end

        # 2. Allowed read-only coeffects must work
        results[:read_require] = ctx.require("allowed_service")
        results[:read_get] = ctx.get("allowed_service")
        results[:read_has] = ctx.has?("allowed_service")
        results[:read_satisfied] = ctx.satisfied?(["allowed_service"])
        results[:read_coeffect] = ctx.coeffect("allowed_service")

        # 3. Blocked coeffects must return nil / raise CoeffectMissingError
        results[:blocked_get_guard] = ctx.get("guard")
        begin
          ctx.require("guard")
          results[:require_guard_blocked] = false
        rescue => e
          results[:require_guard_blocked] = true
          results[:require_guard_error] = e.class.to_s
        end

        results
      end
    RUBY

    res = @tool.execute(
      "name" => "security_probe_tool",
      "description" => "Tests context sealing",
      "code" => code,
      "scope" => "session"
    )
    assert_includes res, "Successfully synthesized"

    probe_tool = @registry.get("security_probe_tool")
    assert probe_tool
    out = probe_tool.execute({})

    # Verify all mutations are blocked
    assert_equal true, out[:dispose_blocked], "ctx.dispose must be blocked with NoMethodError"
    refute @runtime_context.disposed?, "Runtime context must not be disposed by synthesized tool"
    assert_equal true, out[:provide_blocked], "ctx.provide must be blocked with NoMethodError"
    assert_nil @runtime_context.get("malicious"), "Poisoned service must not be provided"
    assert_equal true, out[:unprovide_blocked], "ctx.unprovide must be blocked with NoMethodError"
    assert_equal true, out[:parent_blocked], "ctx.parent must be blocked with NoMethodError"
    assert_equal true, out[:extend_blocked], "ctx.extend must be blocked with NoMethodError"

    # Verify read-only access succeeds
    assert_equal "service_42", out[:read_require]
    assert_equal "service_42", out[:read_get]
    assert_equal true, out[:read_has]
    assert_equal true, out[:read_satisfied]
    assert_equal "service_42", out[:read_coeffect]

    # Verify blocked coeffects
    assert_nil out[:blocked_get_guard]
    assert_equal true, out[:require_guard_blocked]
    assert_includes out[:require_guard_error], "CoeffectMissingError"
  end

  def test_remediation_custom_subagent_blocks_write_risk_synthesized_tools
    source_reg = Rubik::Tools::Registry.new

    read_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "custom_read_tool", description: "Reads stats", risk: :read, params_schema: {}); end
      def execute(_a = {}); { ok: true }; end
    end.new
    source_reg.register(read_tool, origin: :synthesis)

    write_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "custom_write_tool", description: "Writes stats", risk: :write, params_schema: {}); end
      def execute(_a = {}); { ok: true }; end
    end.new
    source_reg.register(write_tool, origin: :synthesis)

    exec_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "custom_exec_tool", description: "Executes action", risk: :execute, params_schema: {}); end
      def execute(_a = {}); { ok: true }; end
    end.new
    source_reg.register(exec_tool, origin: :synthesis)

    # 1. Custom subagent without write grant
    custom_ro = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "auditor",
      description: "Read only auditor",
      grants: [],
      tool_filter: Rubik::Orchestrator::Subagent::ProfileContract.tool_filter([]),
      enable_write_tools: false
    )
    child_ctx = Rubik::Runtime::Context.new
    scoped_ro = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: custom_ro,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    assert scoped_ro.get("custom_read_tool"), "Read-risk tool must be allowed for read-only subagent"
    refute scoped_ro.get("custom_write_tool"), "Write-risk tool must be blocked for read-only subagent"
    refute scoped_ro.get("custom_exec_tool"), "Execute-risk tool must be blocked for read-only subagent"

    # 2. Custom subagent with write grant
    custom_rw = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "builder",
      description: "Read write builder",
      grants: ["write"],
      tool_filter: Rubik::Orchestrator::Subagent::ProfileContract.tool_filter(["write"]),
      enable_write_tools: true
    )
    child_ctx2 = Rubik::Runtime::Context.new
    scoped_rw = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: custom_rw,
      child_ctx: child_ctx2,
      buffer: nil,
      parent_buffer: nil
    )

    assert scoped_rw.get("custom_read_tool"), "Read-risk tool must be allowed for write-enabled subagent"
    assert scoped_rw.get("custom_write_tool"), "Write-risk tool must be allowed for write-enabled subagent"
    assert scoped_rw.get("custom_exec_tool"), "Execute-risk tool must be allowed for write-enabled subagent"
  end

  def test_remediation_multi_arity_filter_explicit_rejection_honored
    source_reg = Rubik::Tools::Registry.new

    allowed_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "allowed_tool", description: "Allowed tool", risk: :read, params_schema: {}); end
      def execute(_a = {}); { ok: true }; end
    end.new
    source_reg.register(allowed_tool, origin: :synthesis)

    rejected_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "rejected_tool", description: "Rejected tool", risk: :read, params_schema: {}); end
      def execute(_a = {}); { ok: true }; end
    end.new
    source_reg.register(rejected_tool, origin: :synthesis)

    # Multi-arity filter (3-arity) explicitly rejects 'rejected_tool'
    rejecting_filter = ->(name, _tool, _origin) { name != "rejected_tool" }
    type_def = Rubik::Orchestrator::Subagent::TypeDefinition.new(
      name: "research",
      description: "Research subagent with custom filter",
      tool_filter: rejecting_filter
    )

    scoped = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: type_def,
      child_ctx: Rubik::Runtime::Context.new,
      buffer: nil,
      parent_buffer: nil
    )

    assert scoped.get("allowed_tool"), "Tool passing filter must be registered"
    refute scoped.get("rejected_tool"), "Tool rejected by multi-arity filter must NOT be registered"
  end

  def test_remediation_rebind_isolation_auto_provisions_scoped_registry
    parent_reg = Rubik::Tools::Registry.new
    parent_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize; super(name: "parent_tool", description: "Parent tool", risk: :read, params_schema: {}); end
      def execute(_a = {}); {}; end
    end.new
    parent_reg.register(parent_tool)

    synth_tool = Rubik::Tools::SynthesizeToolTool.new(parent_reg, @storage, @guard)

    # 1. Rebinding to context without pre-existing tool_registry
    child_ctx = Rubik::Runtime::Context.new
    rebound = synth_tool.rebind_to(child_ctx)

    # Rebound tool creates a tool in the scoped context
    res = rebound.execute(
      "name" => "child_only_tool",
      "description" => "Child only tool",
      "code" => "->(args) { { child: true } }",
      "scope" => "session"
    )
    assert_includes res, "Successfully synthesized"

    # Parent registry must NOT have received child_only_tool
    assert_nil parent_reg.get("child_only_tool"), "Parent registry must remain unmutated"

    # Child context's auto-provisioned registry must have child_only_tool
    child_reg = child_ctx.get(Rubik::Coeffects::TOOL_REGISTRY)
    assert child_reg, "Child context must have an auto-provisioned tool registry"
    assert child_reg.get("child_only_tool"), "Child registry must contain the synthesized tool"

    # 2. Symmetrical verification for UnsynthesizeTool
    unsynth_tool = Rubik::Tools::UnsynthesizeTool.new(nil, parent_reg, @storage)
    unsynth_rebound = unsynth_tool.rebind_to(child_ctx)
    assert unsynth_rebound, "UnsynthesizeTool rebind_to must succeed"
  end
end
