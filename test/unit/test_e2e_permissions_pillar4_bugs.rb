# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/tools/registry"
require_relative "../../lib/rubik/tools/builtins/synthesis"
require_relative "../../lib/rubik/tools/builtins/unsynthesize"
require_relative "../../lib/rubik/tools/preflight_runner"
require_relative "../../lib/rubik/runtime/overlay_storage"
require_relative "../../lib/rubik/orchestrator/subagent/scoped_registry"
require_relative "../../lib/rubik/orchestrator/subagent/builtin_types"
require_relative "../../lib/rubik/orchestrator/subagent/type_definition"
require_relative "../../lib/rubik/runtime/context"

# ==============================================================================
# E2E & Integration Test Suite — Pillar 4: Discovered Bugs Remediation & Hardening
# Features 18 - 23 (Tier 1: Feature Coverage & Tier 2: Boundary/Edge Cases)
#
# Specifications:
# - PROJECT.md (Features 18-23: B1 - B6)
# - ORIGINAL_REQUEST.md (R4: Fix Discovered Bugs)
# - permission_architecture_review.md (Deep Audit & Bugs Remediation)
# ==============================================================================
class TestE2EPermissionsPillar4Bugs < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubik_pillar4_test")
    @guard = Rubik::Security::Guard.new
    @registry = Rubik::Tools::Registry.new
    @storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp, home_dir: @tmp)
    @runtime_context = Rubik::Runtime::Context.new
    @runtime_manager = Struct.new(:context).new(@runtime_context)
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ============================================================================
  # Feature 18 (B1): Overlay eval 2-arity
  # (Support 2-arity tool execution on reload in OverlayStorage#eval_tool)
  # ============================================================================

  def test_f18_b1_overlay_eval_tool_supports_2_arity_on_reload
    code = <<~RUBY
      # Description: 2-arity overlay tool
      # Risk: read
      ->(args, ctx) do
        { ok: true, has_ctx: !ctx.nil?, query: args["q"] }
      end
    RUBY

    tool_instance = @storage.eval_tool("overlay_2arity_tool", code, :project)
    assert tool_instance, "OverlayStorage#eval_tool must return an instantiated tool"

    # Execution with 2-arity must succeed without ArgumentError (given 1, expected 2)
    # When executed, if tool passes or provides context, has_ctx is verified
    res = tool_instance.execute("q" => "test_query")
    assert res[:ok] || res["ok"], "2-arity tool loaded from overlay must execute cleanly"
  end

  # ============================================================================
  # Feature 19 (B2): Unsynthesize rebind
  # (Implement rebind_to(ctx) in UnsynthesizeToolTool)
  # ============================================================================

  def test_f19_b2_unsynthesize_tool_implements_rebind_to
    unsynth = Rubik::Tools::UnsynthesizeTool.new(
      nil, @registry, @storage, runtime_manager: @runtime_manager
    )

    assert_respond_to unsynth, :rebind_to, "UnsynthesizeTool must implement rebind_to(ctx)"

    subagent_reg = Rubik::Tools::Registry.new
    subagent_ctx = Rubik::Runtime::Context.new
    subagent_ctx.provide("tool_registry", subagent_reg)

    # Register a tool in subagent_reg
    dummy_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "sub_tool_to_delete", description: "desc", risk: :read, params_schema: {})
      end

      def execute(_args = {})
        { ok: true }
      end
    end.new
    subagent_reg.register(dummy_tool, origin: :synthesis)
    assert subagent_reg.get("sub_tool_to_delete")

    # Rebound unsynthesize should delete from subagent_reg
    rebound_unsynth = unsynth.rebind_to(subagent_ctx)
    res = rebound_unsynth.execute("name" => "sub_tool_to_delete", "kind" => "tool", "scope" => "session")

    assert_includes res, "Successfully deleted tool"
    refute subagent_reg.get("sub_tool_to_delete"), "Tool should be removed from subagent registry"
  end

  # ============================================================================
  # Feature 20 (B3): String params_schema
  # (Parse JSON string params_schema in SynthesizeToolTool)
  # ============================================================================

  def test_f20_b3_synthesize_tool_parses_json_string_params_schema
    tool = Rubik::Tools::SynthesizeToolTool.new(
      @registry, @storage, @guard, runtime_manager: @runtime_manager
    )

    json_schema_str = '{"type": "object", "properties": {"val": {"type": "integer"}}, "required": ["val"]}'
    code = '->(args) { { doubled: args["val"].to_i * 2 } }'

    res = tool.execute(
      "name" => "schema_str_tool",
      "description" => "Tool with string schema",
      "params_schema" => json_schema_str,
      "code" => code,
      "scope" => "session",
      "test_args" => { "val" => 21 }
    )

    assert_includes res, "Successfully synthesized"
    tool_inst = @registry.get("schema_str_tool")
    assert tool_inst, "Tool must be registered"
    assert_kind_of Hash, tool_inst.declaration.params_schema,
                   "Tool params_schema must be parsed into a Ruby Hash, not left as a raw JSON string"
    assert_equal "object", tool_inst.declaration.params_schema["type"] || tool_inst.declaration.params_schema[:type]
  end

  # ============================================================================
  # Feature 21 (B4): Nil runtime manager
  # (Ensure inverse is registered even when @runtime_manager is nil)
  # ============================================================================

  def test_f21_b4_inverse_registration_when_runtime_manager_is_nil
    # Registry initialized with coeffect_ctx (spatiotemporal context)
    registry_with_ctx = Rubik::Tools::Registry.new(coeffect_ctx: @runtime_context)
    tool = Rubik::Tools::SynthesizeToolTool.new(
      registry_with_ctx, @storage, @guard,
      runtime_manager: nil
    )

    code = "->(args) { { ok: true } }"
    res = tool.execute(
      "name" => "nil_mgr_tool",
      "code" => code,
      "scope" => "session"
    )

    assert_includes res, "Successfully synthesized"
    assert registry_with_ctx.get("nil_mgr_tool")

    # When context is disposed, inverse should unregister the tool
    @runtime_context.dispose
    refute registry_with_ctx.get("nil_mgr_tool"), "Disposing context must unregister tool even when runtime_manager was nil"
  end

  # ============================================================================
  # Feature 22 (B5): Tool origin preservation
  # (Preserve origin: in ScopedRegistry.build)
  # ============================================================================

  def test_f22_b5_scoped_registry_preserves_tool_origin
    source_reg = Rubik::Tools::Registry.new

    tool_synth = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "synth_tool", description: "Synthesized tool", risk: :read, params_schema: {})
      end

      def execute(_args = {}) = {}
    end.new
    source_reg.register(tool_synth, origin: :synthesis)
    assert_equal :synthesis, source_reg.origin("synth_tool")

    tool_overlay = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "overlay_tool", description: "Overlay tool", risk: :read, params_schema: {})
      end

      def execute(_args = {}) = {}
    end.new
    source_reg.register(tool_overlay, origin: :overlay)
    assert_equal :overlay, source_reg.origin("overlay_tool")

    type_defs = Rubik::Orchestrator::Subagent::BuiltinTypes.default_definitions(
      Rubik::Orchestrator::Subagent::TypeDefinition
    )
    coder_def = type_defs.find { |d| d.name == "coder" }
    child_ctx = Rubik::Runtime::Context.new

    child_reg = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: source_reg,
      type_def: coder_def,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    # ScopedRegistry must preserve the original origin (:synthesis, :overlay) instead of resetting to default :builtin
    assert_equal :synthesis, child_reg.origin("synth_tool"), "Tool origin :synthesis must be preserved in child registry"
    assert_equal :overlay, child_reg.origin("overlay_tool"), "Tool origin :overlay must be preserved in child registry"
  end

  # ============================================================================
  # Feature 23 (B6): Preflight verdict parsing
  # (Anchor JSON verdict parsing in PreflightRunner)
  # ============================================================================

  def test_f23_b6_preflight_runner_parses_anchored_verdict_with_stdout_noise
    # When child outputs warnings or noise to stdout before or after the JSON verdict line
    noisy_output_success = <<~OUT
      [DEBUG] Initializing custom runner...
      {"foo": "some logging data with braces"}
      {"ok":true}
    OUT

    verdict_success = Rubik::Tools::PreflightRunner.parse_verdict(noisy_output_success)
    assert_nil verdict_success, "parse_verdict should extract ok: true despite extraneous stdout logs"

    noisy_output_error = <<~OUT
      Warning: gem deprecation notice
      {"ok":false,"error":"StandardError: division by zero"}
      Cleaning up resources...
    OUT

    verdict_error = Rubik::Tools::PreflightRunner.parse_verdict(noisy_output_error)
    assert_includes verdict_error, "division by zero", "parse_verdict should correctly parse error verdict"
  end

  # ============================================================================
  # Tier 2: Boundary & Corner Cases for Pillar 4
  # ============================================================================

  def test_tier2_boundary_malformed_json_params_schema
    tool = Rubik::Tools::SynthesizeToolTool.new(
      @registry, @storage, @guard, runtime_manager: @runtime_manager
    )

    invalid_json = '{"type": "object", broken json...'
    code = "->(args) { { ok: true } }"

    res = tool.execute(
      "name" => "broken_schema_tool",
      "params_schema" => invalid_json,
      "code" => code,
      "scope" => "session"
    )

    # Should report an error rather than crashing
    assert_includes res.to_s.downcase, "schema"
    refute @registry.get("broken_schema_tool")
  end

  def test_tier2_boundary_preflight_verdict_empty_or_no_json
    empty_output = "No json here\nJust random text\n"
    verdict = Rubik::Tools::PreflightRunner.parse_verdict(empty_output)
    assert_includes verdict, "no verdict", "Missing verdict JSON should report clear error"
  end

  # ============================================================================
  # Review hardening: exit / forged-verdict / strict-boolean pins
  # ============================================================================

  def test_review_exit_call_is_blocked_by_synthesis_gate
    # Kernel#exit raises SystemExit, which preflight cannot always contain —
    # when verification runs in-process it would kill the host. The gate must
    # deny it up front, exactly like exit!.
    guard = Rubik::Security::Guard.new
    assert_raises(Rubik::Security::BlockedWriteError) do
      guard.verify_synthesis_safety!("->(args) { exit }")
    end
  end

  def test_review_systemexit_after_fake_verdict_fails_preflight
    # `raise SystemExit` passes the gate (it is not a Kernel#exit call). A
    # handler that prints a fake {"ok":true} and then raises SystemExit used
    # to leave the fake as the last line with a clean exit — the child must
    # instead emit a genuine failure verdict as the LAST line so the parent's
    # reverse scan reads the truth.
    guard = Rubik::Security::Guard.new
    code = '->(args) { puts %q{{"ok":true}}; raise SystemExit }'
    result = Rubik::Tools::PreflightRunner.run(code, {}, guard: guard, mode: :tool)
    assert result.is_a?(String), "forged-then-exit handler must fail preflight, got: #{result.inspect}"
  end

  def test_review_verdict_ok_must_be_strict_boolean
    # {"ok":"false"} / {"ok":1} are truthy in Ruby; only a real boolean true
    # may read as preflight success.
    refute_nil Rubik::Tools::PreflightRunner.parse_verdict("{\"ok\":\"false\"}\n"),
               "string ok value must not count as success"
    refute_nil Rubik::Tools::PreflightRunner.parse_verdict("{\"ok\":1}\n"),
               "numeric ok value must not count as success"
    assert_nil Rubik::Tools::PreflightRunner.parse_verdict("{\"ok\":true}\n"),
               "real boolean true is still a success"
  end
end
