# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/subagent"
require_relative "../../lib/rubik/tools/builtins/define_subagent"

# Unit pins for the subagent tool surface: the shared SubagentToolHelpers
# resolution chain and the error paths of Invoke/Manage/DefineSubagentTool.
# Happy-path orchestration (spawn formatting, wait/status rendering,
# extend/resume/redeploy/reap/kill, archetype inference) is pinned with a
# REAL supervisor in test_subagent_orchestration.rb, test_subagent_resilience.rb,
# test_subagent_narration.rb, test_session_review_bugfixes.rb and
# test_subagent_reuse_and_reap.rb — this file deliberately does not restate
# those; it covers the branches those suites never execute (missing
# supervisor, empty specs, spawn failure, missing params, empty list,
# attention states, status id guards).
class TestSubagentTools < Minitest::Test
  class DummyTypeRegistry
    attr_reader :defined_types

    def initialize
      @defined_types = []
    end

    def define_custom(name:, description:, system_prompt:, requires: [], grants: Rubik::Orchestrator::Subagent::ProfileContract::UNSET,
                      enable_write_tools: nil, enable_subagent_tools: nil, **_rest)
      profile = Rubik::Orchestrator::Subagent::ProfileContract.validate(
        name: name, description: description, system_prompt: system_prompt, requires: requires, grants: grants,
        enable_write_tools: enable_write_tools, enable_subagent_tools: enable_subagent_tools
      )
      write_enabled = profile.grants.include?("write")
      spawn_enabled = profile.grants.include?("subagent_spawn")
      type_def = Struct.new(:name, :description, :system_prompt, :requires, :grants,
                            :enable_write_tools, :enable_subagent_tools).new(
                              profile.name, profile.description, profile.system_prompt, profile.requires, profile.grants,
                              write_enabled, spawn_enabled
                            )
      @defined_types << type_def
      type_def
    end
  end

  class DummySubagentInstance
    attr_accessor :id, :role, :type_name, :type, :state, :max_steps, :current_step, :uptime, :history, :last_error, :transcript, :root_dir

    def initialize(id: "subagent-1", role: "Researcher", type_name: "research", state: :completed, max_steps: 10, current_step: 3, uptime: 1.5, root_dir: "/tmp/fake_ws")
      @id = id
      @role = role
      @type_name = type_name
      @type = type_name
      @state = state
      @max_steps = max_steps
      @current_step = current_step
      @uptime = uptime
      @history = ["msg1", "msg2"]
      @last_error = nil
      @transcript = "rubik://storage/test/transcripts/subagent-1.jsonl"
      @root_dir = root_dir
    end

    def running?
      @state == :running
    end

    def to_h
      {
        id: @id,
        role: @role,
        type: @type_name,
        state: @state,
        max_steps: @max_steps,
        current_step: @current_step,
        uptime: @uptime
      }
    end
  end

  class DummySupervisor
    attr_accessor :default_max_steps, :spawn_batch_result, :instances, :wait_for_result,
                  :extend_budget_result, :resume_result, :resume_all_result,
                  :redeploy_result, :reap_result, :kill_result, :kill_all_result, :root_dir
    attr_reader :type_registry, :spawned_specs, :killed_ids

    def initialize(root_dir: "/tmp/fake_ws")
      @default_max_steps = 15
      @type_registry = DummyTypeRegistry.new
      @spawned_specs = []
      @spawn_batch_result = nil
      @instances = {}
      @wait_for_result = []
      @extend_budget_result = true
      @resume_result = true
      @resume_all_result = ["subagent-1"]
      @redeploy_result = nil
      @reap_result = ["subagent-1"]
      @kill_result = true
      @killed_ids = []
      @kill_all_result = true
      @root_dir = root_dir
    end

    def spawn_batch(specs, owner: nil)
      @last_owner = owner
      @spawned_specs << specs
      return @spawn_batch_result if @spawn_batch_result

      specs.map.with_index do |s, i|
        inst = DummySubagentInstance.new(
          id: "subagent-#{i + 1}",
          role: s[:role] || "Worker",
          type_name: s[:type_name] || "research",
          state: :running,
          root_dir: @root_dir
        )
        [:launched, inst]
      end
    end

    def list
      @instances.values
    end

    def get(id)
      @instances[id]
    end

    def wait_for(_ids, timeout: 5) # rubocop:disable Lint/UnusedMethodArgument
      @wait_for_result
    end

    def extend_budget(id, steps)
      inst = get(id)
      inst.max_steps += steps if inst && @extend_budget_result
      @extend_budget_result
    end

    def resume(id, additional_steps: nil) # rubocop:disable Lint/UnusedMethodArgument
      inst = get(id)
      inst.state = :running if inst && @resume_result
      @resume_result
    end

    def resume_all
      @resume_all_result
    end

    def redeploy(id, prompt:, max_steps: nil) # rubocop:disable Lint/UnusedMethodArgument
      raise StandardError, "Subagent not found" if @redeploy_result.is_a?(StandardError)

      inst = get(id) || DummySubagentInstance.new(id: id, state: :running, root_dir: @root_dir)
      inst.state = :running
      inst.max_steps = max_steps || inst.max_steps
      inst
    end

    def reap_finished!(force: false) # rubocop:disable Lint/UnusedMethodArgument
      @reap_result
    end

    def kill(id, cascade: true) # rubocop:disable Lint/UnusedMethodArgument
      @killed_ids << id
      @kill_result
    end

    def kill_all
      @kill_all_result
    end
  end

  class DummyContext
    def initialize(coeffects = {})
      @coeffects = coeffects
    end

    def get(key)
      @coeffects[key]
    end

    def respond_to?(msg, include_all = false) # rubocop:disable Style/OptionalBooleanParameter
      msg == :get || super
    end
  end

  class DummyToolWithHelpers
    include Rubik::Tools::SubagentToolHelpers
  end

  # =========================================================================
  # 1. SubagentToolHelpers
  # =========================================================================

  def test_resolve_supervisor_prefers_the_direct_argument_over_the_context
    direct = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    contextual = DummySupervisor.new(root_dir: "/tmp/ctx_ws")
    ctx = DummyContext.new(Rubik::Coeffects::SUBAGENT_SUPERVISOR => contextual)
    helper = DummyToolWithHelpers.new

    assert_equal direct, helper.resolve_supervisor(direct, ctx)
  end

  def test_resolve_supervisor_from_runtime_context_coeffect
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    ctx = DummyContext.new(Rubik::Coeffects::SUBAGENT_SUPERVISOR => sup)
    helper = DummyToolWithHelpers.new

    assert_equal sup, helper.resolve_supervisor(nil, ctx)
  end

  def test_resolve_supervisor_returns_nil_when_unresolvable
    helper = DummyToolWithHelpers.new

    assert_nil helper.resolve_supervisor(nil, nil)
    assert_nil helper.resolve_supervisor(nil, Object.new), "objects without #get are not a coeffect context"
  end

  # =========================================================================
  # 2. InvokeSubagentTool
  # =========================================================================

  def test_invoke_subagent_missing_supervisor
    tool = Rubik::Tools::InvokeSubagentTool.new
    res = tool.execute(role: "Researcher", prompt: "Investigate bug")

    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_invoke_subagent_missing_specs
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    res = tool.execute({})
    assert res.error?
    assert_includes res.to_s, "No valid subagents specified"

    res_empty_arr = tool.execute(subagents: [])
    assert res_empty_arr.error?, "an explicit empty array is the same contract violation"
  end

  def test_invoke_subagent_handles_spawn_error
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    def sup.spawn_batch(_specs, **_kwargs)
      raise StandardError, "Max concurrency limit reached"
    end

    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)
    res = tool.execute(role: "Tester", prompt: "Run tests")

    assert res.error?
    assert_includes res.to_s, "Failed to invoke subagent(s): Max concurrency limit reached"
  end

  # =========================================================================
  # 3. ManageSubagentsTool
  # =========================================================================

  def test_manage_subagents_missing_supervisor
    tool = Rubik::Tools::ManageSubagentsTool.new
    res = tool.execute(action: "list")

    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_manage_subagents_list_empty
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "list")
    assert_equal "No active or tracked subagents.", res.to_s
  end

  def test_manage_subagents_list_with_attention_states
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    inst1 = DummySubagentInstance.new(id: "subagent-1", role: "Worker", state: :completed, root_dir: "/tmp/fake_ws")
    inst2 = DummySubagentInstance.new(id: "subagent-2", role: "Stalled", state: :budget_exhausted, root_dir: "/tmp/fake_ws")
    inst2.last_error = "Budget exceeded max limit"

    sup.instances = { "subagent-1" => inst1, "subagent-2" => inst2 }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "list")
    assert_includes res.to_s, "1 subagent(s) need attention:"
    assert_includes res.to_s, "[subagent-2] 'Stalled' — BUDGET_EXHAUSTED"
  end

  def test_manage_subagents_status_requires_a_known_id
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res_err = tool.execute(action: "status")
    assert res_err.error?
    assert_includes res_err.to_s, "Missing required parameter 'conversation_id'"

    res_not_found = tool.execute(action: "status", conversation_id: "subagent-99")
    assert res_not_found.error?
    assert_includes res_not_found.to_s, "Subagent 'subagent-99' not found"
  end

  # =========================================================================
  # 4. DefineSubagentTool
  # =========================================================================

  def test_define_subagent_missing_supervisor
    tool = Rubik::Tools::DefineSubagentTool.new
    res = tool.execute(name: "custom", description: "desc", system_prompt: "prompt")

    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_define_subagent_missing_required_params
    sup = DummySupervisor.new(root_dir: "/tmp/fake_ws")
    tool = Rubik::Tools::DefineSubagentTool.new(supervisor: sup)

    res = tool.execute(name: "custom", description: "")
    assert res.error?
    payload = JSON.parse(res.to_s)
    assert_equal "invalid_subagent_profile", payload.fetch("error")
    assert_includes payload.fetch("errors").map { |item| item.fetch("code") }, "required"
  end
end
