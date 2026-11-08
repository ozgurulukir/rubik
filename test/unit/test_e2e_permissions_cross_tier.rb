# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/tools/registry"
require_relative "../../lib/rubik/tools/builtins/synthesis"
require_relative "../../lib/rubik/tools/builtins/unsynthesize"
require_relative "../../lib/rubik/tools/builtins/exec"
require_relative "../../lib/rubik/runtime/overlay_storage"
require_relative "../../lib/rubik/orchestrator/subagent/scoped_registry"
require_relative "../../lib/rubik/orchestrator/subagent/builtin_types"
require_relative "../../lib/rubik/orchestrator/subagent/type_definition"
require_relative "../../lib/rubik/runtime/context"
require_relative "../../lib/rubik/cli/workspace_trust"
require_relative "../../lib/rubik/ui/approvals"
begin
  require_relative "../../lib/rubik/repl/synthesized_command_context"
rescue LoadError
  # Expected before Feature 11 implementation
end

# ==============================================================================
# E2E & Integration Test Suite — Cross-Tier: Cross-Feature & Real-World Scenarios
# Tier 3 (Cross-Feature Interactions) & Tier 4 (Real-World Application Scenarios)
#
# Specifications:
# - PROJECT.md (Interface Contracts & Milestones M1-M5)
# - ORIGINAL_REQUEST.md (Acceptance Criteria & Verification)
# - permission_architecture_review.md (Holistic System Architecture)
# - AGENTS.md (Spatiotemporal Composability & Revertible Effects)
# ==============================================================================
class TestE2EPermissionsCrossTier < Minitest::Test
  Classifier = Rubik::Security::Classifier
  Guard = Rubik::Security::Guard
  BlockedWriteError = Rubik::Security::BlockedWriteError

  def setup
    @tmp = Dir.mktmpdir("rubik_crosstier_test")
    @guard = Guard.new
    @registry = Rubik::Tools::Registry.new
    @storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp, home_dir: @tmp)
    @runtime_context = Rubik::Runtime::Context.new
    @runtime_manager = Struct.new(:context).new(@runtime_context)
    @synth_tool = Rubik::Tools::SynthesizeToolTool.new(
      @registry, @storage, @guard, runtime_manager: @runtime_manager
    )
    @unsynth_tool = Rubik::Tools::UnsynthesizeTool.new(
      nil, @registry, @storage, runtime_manager: @runtime_manager
    )
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ============================================================================
  # Tier 3: Cross-Feature Interactions
  # ============================================================================

  # Cross 1: Tool Synthesis -> ScopedRegistry propagation -> 2-arity execution -> Unsynthesize
  def test_cross_feature_1_synthesis_propagation_execution_and_unsynthesis
    @runtime_context.provide("metrics_db", { "queries_run" => 42 })

    # Step 1: Synthesize a 2-arity tool with risk: :write
    tool_code = <<~RUBY
      ->(args, ctx) do
        db = ctx.require("metrics_db")
        { status: "ok", total: db["queries_run"] + args["delta"].to_i }
      end
    RUBY

    res_synth = @synth_tool.execute(
      "name" => "update_metrics",
      "description" => "Updates system metrics",
      "risk" => "write",
      "code" => tool_code,
      "scope" => "session",
      "test_args" => { "delta" => 8 }
    )
    assert_includes res_synth, "Successfully synthesized"
    assert @registry.get("update_metrics")

    # Step 2: Build ScopedRegistry for :coder subagent
    type_defs = Rubik::Orchestrator::Subagent::BuiltinTypes.default_definitions(
      Rubik::Orchestrator::Subagent::TypeDefinition
    )
    coder_def = type_defs.find { |d| d.name == "coder" }
    child_ctx = @runtime_context.extend

    coder_reg = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: @registry,
      type_def: coder_def,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    # Tool must propagate to :coder subagent
    subagent_tool = coder_reg.get("update_metrics")
    assert subagent_tool, "Synthesized tool must be visible in coder subagent toolbelt"
    assert_equal :synthesis, coder_reg.origin("update_metrics"), "Origin :synthesis must be preserved"

    # Step 3: Execute tool in subagent context
    exec_result = subagent_tool.execute("delta" => 10)
    assert_equal "ok", exec_result[:status] || exec_result["status"]
    assert_equal 52, exec_result[:total] || exec_result["total"]

    # Step 4: Rebind unsynthesize tool and delete
    rebound_unsynth = @unsynth_tool.rebind_to(child_ctx)
    res_delete = rebound_unsynth.execute("name" => "update_metrics", "kind" => "tool", "scope" => "session")
    assert_includes res_delete, "Successfully deleted tool"
  end

  # Cross 2: Ruby Synthesis Decoupling + Collection :delete + Sealed Context Execution
  def test_cross_feature_2_synthesis_decoupling_delete_and_sealed_execution
    # Synthesize a bang-command that uses both:
    # 1. Variables matching shell names (node, source, sh)
    # 2. Collection .delete(:key)
    # 3. Sealed ctx.out.puts
    cmd_code = <<~'RUBY'
      ->(args, ctx) do
        node = args["node"] || "default"
        source = args["source"] || "main"
        config_map = { "node" => node, "source" => source, "secret" => "xyz" }
        config_map.delete("secret")
        ctx.puts("Filtered keys: #{config_map.keys.sort.join(', ')}")
      end
    RUBY

    # Verify Guard passes code
    assert @guard.verify_synthesis_safety!(cmd_code)

    # Execute under SynthesizedCommandContext
    out_io = StringIO.new
    sctx = if defined?(Rubik::REPL::SynthesizedCommandContext)
             Rubik::REPL::SynthesizedCommandContext.new(output: out_io, coeffects: {})
           else
             Struct.new(:out) { def puts(*a); out.puts(*a); end }.new(out_io)
           end

    eval_handler = eval(cmd_code, Object.new.instance_eval { binding }, __FILE__, __LINE__)
    eval_handler.call({ "node" => "ast_1", "source" => "input.rb" }, sctx)

    assert_includes out_io.string, "Filtered keys: node, source"
    refute_includes out_io.string, "secret"
  end

  # Cross 3: Newly Added Toolchain (bundle, rake) + Workspace Trust + Discovery Integration
  def test_cross_feature_3_toolchain_yaml_with_workspace_trust_and_discovery
    workspace_dir = File.join(@tmp, "cross_ruby_project")
    FileUtils.mkdir_p(workspace_dir)

    # Discovery candidates for Ruby
    ruby_markers = Rubik::Runtime::Discovery::TEST_RUNNER_MARKERS["ruby"]
    all_candidates = ruby_markers.flat_map { |m| m[:candidates] }.uniq

    # In trusted workspace, all discovered candidates must be recognized and safe
    assert Rubik::CLI::WorkspaceTrust.trusted?(workspace_dir)

    all_candidates.each do |candidate|
      res = Classifier.classify(candidate)
      assert_includes [:readonly, :local_effects], res.classification,
                      "Candidate #{candidate} must not be classified as unknown or dangerous"
      assert @guard.verify_command_safety!(candidate),
             "Candidate #{candidate} must pass guard verification in trusted workspace"
    end
  end

  # Cross 4: Subagent Command Execution vs Paket D Protection + Human Keypress Approval
  def test_cross_feature_4_subagent_vs_paket_d_and_interactive_approval
    fake_shell = Struct.new(:agent_caller, :interactive_input, :input, :output, :config, :commands) do
      def interactive_input?
        interactive_input
      end

      def execute_input(str)
        if agent_caller && (str.include?("security.") || str.include?("!allow-cmd"))
          return "Security Error: operator only"
        end
        "ok"
      end
    end.new(true, true, StringIO.new("y\n"), StringIO.new, {}, { "allow-cmd" => { audience: :human, handler: ->(*) {} } })

    # 1. Subagent cannot self-allowlist via !allow-cmd
    registry = Rubik::Tools::Registry.new
    registry.register(Rubik::Tools::ExecReplCommandTool.new(fake_shell))
    allow_res = registry.get("exec_repl_command").execute("command" => '!allow-cmd add "custom_binary"')
    assert_includes allow_res, "reserved for the human operator"

    # 2. When subagent runs an unknown safe command interactively, operator prompt is requested
    prompt_asked = false
    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_sh, _q, **_o) { prompt_asked = true; "y" }) do
      res = @guard.verify_command_safety!("./scripts/safe_custom_build", shell: fake_shell)
      assert res
      assert prompt_asked, "Operator keypress approval should be queried for unknown binary"
    end
  end

  # ============================================================================
  # Tier 4: Real-World Application Scenarios
  # ============================================================================

  # Scenario 1: Autonomous Developer Tool Synthesis with 2-Arity Coeffects & Preflight
  def test_scenario_1_autonomous_developer_tool_synthesis
    # Step 1: Provide storage service in runtime context
    storage_mock = { "app_name" => "Rubik", "build_count" => 100 }
    @runtime_context.provide("storage", storage_mock)

    # Step 2: Agent synthesizes a custom project statistics tool
    stats_tool_code = <<~RUBY
      ->(args, ctx) do
        store = ctx.require("storage")
        factor = args.fetch("multiplier", 1).to_i
        { app: store["app_name"], total_builds: store["build_count"] * factor }
      end
    RUBY

    res = @synth_tool.execute(
      "name" => "project_stats",
      "description" => "Calculates project build stats",
      "risk" => "read",
      "code" => stats_tool_code,
      "scope" => "session",
      "test_args" => { "multiplier" => 2 }
    )
    assert_includes res, "Successfully synthesized"
    assert_includes res, "Pre-flight verified with provided test_args"

    # Step 3: Spawn a research subagent and verify tool availability
    type_defs = Rubik::Orchestrator::Subagent::BuiltinTypes.default_definitions(
      Rubik::Orchestrator::Subagent::TypeDefinition
    )
    research_def = type_defs.find { |d| d.name == "research" }
    child_ctx = @runtime_context.extend

    research_reg = Rubik::Orchestrator::Subagent::ScopedRegistry.build(
      source_registry: @registry,
      type_def: research_def,
      child_ctx: child_ctx,
      buffer: nil,
      parent_buffer: nil
    )

    tool_in_research = research_reg.get("project_stats")
    assert tool_in_research, "Tool with risk: :read must be visible to research subagent"

    # Step 4: Execute tool and collect findings
    findings = tool_in_research.execute("multiplier" => 5)
    assert_equal "Rubik", findings[:app] || findings["app"]
    assert_equal 500, findings[:total_builds] || findings["total_builds"]
  end

  # Scenario 2: Dynamic Project-Level Command with Safe Cleanups & Overlay Reload
  def test_scenario_2_dynamic_project_command_with_overlay_reload
    cmd_name = "clean_keys"
    cmd_code = <<~RUBY
      # Description: Cleans sensitive keys
      ->(args, ctx) do
        data = { "token" => "secret_123", "user" => args["user"] || "anonymous" }
        data.delete("token")
        ctx.puts("Cleaned data: \#{data.inspect}")
      end
    RUBY

    # Save to project overlay
    save_res = @storage.save_command(cmd_name, cmd_code, scope: :project, description: "Cleans sensitive keys")
    assert save_res[:ok], "Command must save successfully to overlay"

    # Create fresh shell and reload commands
    shell = Struct.new(:commands, :output) do
      def register_command(name, description: nil, custom: false, &handler)
        self.commands ||= {}
        self.commands[name] = { description: description, custom: custom, handler: handler }
        true
      end
    end.new({}, StringIO.new)

    loaded = @storage.load_all(shell, :project)
    assert_includes loaded, cmd_name, "Command must be loaded by OverlayStorage#load_all"

    # Execute loaded command with sealed context
    out_io = StringIO.new
    sctx = if defined?(Rubik::REPL::SynthesizedCommandContext)
             Rubik::REPL::SynthesizedCommandContext.new(output: out_io, coeffects: {})
           else
             Struct.new(:out) { def puts(*a); out.puts(*a); end }.new(out_io)
           end

    shell.commands[cmd_name][:handler].call({ "user" => "alice" }, sctx)
    assert_includes out_io.string, '"user" => "alice"'
    refute_includes out_io.string, "secret_123"
  end

  # Scenario 3: Interactive Operator Approval Workflow for Custom Toolchain
  def test_scenario_3_operator_approval_workflow_for_custom_toolchain
    interactive_shell = Struct.new(:interactive_input, :input, :output) do
      def interactive_input?
        true
      end
    end.new(true, StringIO.new, StringIO.new)

    # 1. Operator answers 'y': command allowed
    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_sh, _q, **_o) { "y" }) do
      res = @guard.verify_command_safety!("./scripts/build_assets.sh", shell: interactive_shell)
      assert res, "Command must succeed when operator approves"
    end

    # 2. Operator answers 'n': command blocked
    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_sh, _q, **_o) { "n" }) do
      assert_raises(BlockedWriteError) do
        @guard.verify_command_safety!("./scripts/build_assets.sh", shell: interactive_shell)
      end
    end
  end

  # Scenario 4: Revertible Sub-Context Lifecycle & State Isolation (AGENTS.md §1.A)
  def test_scenario_4_revertible_subcontext_lifecycle_and_state_isolation
    # Spatiotemporal Composability: Creating a sub-context and registering a revertible tool
    parent_ctx = Rubik::Runtime::Context.new
    child_ctx = parent_ctx.extend

    sub_registry = Rubik::Tools::Registry.new
    child_ctx.provide("tool_registry", sub_registry)

    # Tool registered in child context
    ephemeral_tool = Class.new(Rubik::Tools::BaseTool) do
      def initialize
        super(name: "ephemeral_task_tool", description: "Temporary tool", risk: :read, params_schema: {})
      end

      def execute(_args = {}); { temp: true }; end
    end.new

    sub_registry.register(ephemeral_tool, origin: :synthesis)
    child_ctx.on_dispose { sub_registry.unregister("ephemeral_task_tool") }

    assert sub_registry.get("ephemeral_task_tool"), "Tool must exist before dispose"

    # Dispose child context: must unwind inverses in LIFO order without affecting parent
    child_ctx.dispose
    refute sub_registry.get("ephemeral_task_tool"), "Tool must be cleanly unregistered on context dispose"
  end
end
