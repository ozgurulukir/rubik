# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/tools/builtins/subagent"

class TestSubagentTools < Minitest::Test
  class DummyTypeRegistry
    attr_reader :defined_types

    def initialize
      @defined_types = []
    end

    def define_custom(name:, description:, system_prompt:, enable_write_tools:, enable_subagent_tools:)
      type_def = Struct.new(:name, :description, :system_prompt, :enable_write_tools, :enable_subagent_tools).new(
        name, description, system_prompt, enable_write_tools, enable_subagent_tools
      )
      @defined_types << type_def
      type_def
    end
  end

  class DummySubagentInstance
    attr_accessor :id, :role, :type_name, :type, :state, :max_steps, :current_step, :uptime, :history, :last_error, :transcript

    def initialize(id: "subagent-1", role: "Researcher", type_name: "research", state: :completed, max_steps: 10, current_step: 3, uptime: 1.5)
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

    def format_transcript
      "Transcript for #{@id}:\n- User: prompt\n- Assistant: response"
    end
  end

  class DummySupervisor
    attr_accessor :default_max_steps, :spawn_batch_result, :instances, :wait_for_result,
                  :extend_budget_result, :resume_result, :resume_all_result,
                  :redeploy_result, :reap_result, :kill_result, :kill_all_result
    attr_reader :type_registry, :spawned_specs, :killed_ids

    def initialize
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
    end

    def spawn_batch(specs)
      @spawned_specs << specs
      return @spawn_batch_result if @spawn_batch_result

      specs.map.with_index do |s, i|
        inst = DummySubagentInstance.new(
          id: "subagent-#{i + 1}",
          role: s[:role] || "Worker",
          type_name: s[:type_name] || "research",
          state: :running
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

      inst = get(id) || DummySubagentInstance.new(id: id, state: :running)
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

  def test_resolve_supervisor_from_direct_argument
    sup = DummySupervisor.new
    helper = DummyToolWithHelpers.new
    assert_equal sup, helper.resolve_supervisor(sup, nil)
  end

  def test_resolve_supervisor_from_runtime_context_coeffect
    sup = DummySupervisor.new
    ctx = DummyContext.new(Rubik::Coeffects::SUBAGENT_SUPERVISOR => sup)
    helper = DummyToolWithHelpers.new
    assert_equal sup, helper.resolve_supervisor(nil, ctx)
  end

  def test_resolve_supervisor_returns_nil_when_unresolvable
    helper = DummyToolWithHelpers.new
    assert_nil helper.resolve_supervisor(nil, nil)
    assert_nil helper.resolve_supervisor(nil, Object.new)
  end

  # =========================================================================
  # 2. InvokeSubagentTool
  # =========================================================================

  def test_invoke_subagent_declaration
    tool = Rubik::Tools::InvokeSubagentTool.new
    assert_equal "invoke_subagent", tool.name
    assert_equal :execute, tool.risk
    assert tool.declaration.subagent_spawn
    refute tool.declaration.maestro_blocked
    assert_includes tool.aliases, "spawn_subagent"
    assert_includes tool.aliases, "start_subagent"
  end

  def test_invoke_subagent_custom_default_max_steps_schema
    sup = DummySupervisor.new
    sup.default_max_steps = 25
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    schema_desc = tool.params_schema.dig(:properties, :max_steps, :description)
    assert_includes schema_desc, "25"
  end

  def test_invoke_subagent_missing_supervisor
    tool = Rubik::Tools::InvokeSubagentTool.new
    res = tool.execute(role: "Researcher", prompt: "Investigate bug")
    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_invoke_subagent_missing_specs
    sup = DummySupervisor.new
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    res = tool.execute({})
    assert res.error?
    assert_includes res.to_s, "No valid subagents specified"

    res_empty_arr = tool.execute(subagents: [])
    assert res_empty_arr.error?
  end

  def test_invoke_subagent_single_subagent_coder_auto_detection
    sup = DummySupervisor.new
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    tool.execute(role: "Bug Finder", prompt: "Fix the null pointer issue in parser.rb")
    spec = sup.spawned_specs.first.first

    assert_equal "coder", spec[:type_name]
    assert_equal "Bug Finder", spec[:role]
    assert_equal "Fix the null pointer issue in parser.rb", spec[:prompt]
    assert_equal "inherit", spec[:workspace]
  end

  def test_invoke_subagent_single_subagent_research_auto_detection
    sup = DummySupervisor.new
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    tool.execute(role: "Analyst", prompt: "Summarize test coverage across modules")
    spec = sup.spawned_specs.first.first

    assert_equal "research", spec[:type_name]
  end

  def test_invoke_subagent_batch_subagents_invocation
    sup = DummySupervisor.new
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)

    args = {
      subagents: [
        { role: "Researcher", prompt: "Read logs", type_name: "research" },
        { role: "Coder", prompt: "Implement fix", type_name: "coder", max_steps: 20 }
      ]
    }

    res = tool.execute(args)
    assert_kind_of String, res
    assert_includes res, "Launched 2 background subagent(s)"
    assert_equal 2, sup.spawned_specs.first.size
  end

  def test_invoke_subagent_queued_subagents_formatting
    sup = DummySupervisor.new
    queued_spec = Struct.new(:id, :role, :depends_on).new("subagent-2", "Follower", ["subagent-1"])
    launched_inst = DummySubagentInstance.new(id: "subagent-1", role: "Leader", state: :running)

    sup.spawn_batch_result = [
      [:launched, launched_inst],
      [:queued, queued_spec]
    ]

    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: sup)
    res = tool.execute(role: "Leader", prompt: "Do work")

    assert_includes res.to_s, "Launched 1 background subagent(s):"
    assert_includes res.to_s, "Queued 1 subagent(s) on unmet dependencies"
    assert_includes res.to_s, "waiting on: subagent-1"
  end

  def test_invoke_subagent_handles_spawn_error
    sup = DummySupervisor.new
    def sup.spawn_batch(_specs)
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

  def test_manage_subagents_declaration
    tool = Rubik::Tools::ManageSubagentsTool.new
    assert_equal "manage_subagents", tool.name
    assert_equal :read, tool.risk
    assert_includes tool.aliases, "subagents_status"
    assert_includes tool.aliases, "subagent_list"
  end

  def test_manage_subagents_missing_supervisor
    tool = Rubik::Tools::ManageSubagentsTool.new
    res = tool.execute(action: "list")
    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_manage_subagents_list_empty
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "list")
    assert_equal "No active or tracked subagents.", res.to_s
  end

  def test_manage_subagents_list_with_attention_states
    sup = DummySupervisor.new
    inst1 = DummySubagentInstance.new(id: "subagent-1", role: "Worker", state: :completed)
    inst2 = DummySubagentInstance.new(id: "subagent-2", role: "Stalled", state: :budget_exhausted)
    inst2.last_error = "Budget exceeded max limit"

    sup.instances = { "subagent-1" => inst1, "subagent-2" => inst2 }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "list")
    assert_includes res.to_s, "1 subagent(s) need attention:"
    assert_includes res.to_s, "[subagent-2] 'Stalled' — BUDGET_EXHAUSTED"
  end

  def test_manage_subagents_status_action
    sup = DummySupervisor.new
    inst = DummySubagentInstance.new(id: "subagent-1", state: :running)
    sup.instances = { "subagent-1" => inst }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    # Missing ID
    res_err = tool.execute(action: "status")
    assert res_err.error?
    assert_includes res_err.to_s, "Missing required parameter 'conversation_id'"

    # Subagent not found
    res_not_found = tool.execute(action: "status", conversation_id: "subagent-99")
    assert res_not_found.error?
    assert_includes res_not_found.to_s, "Subagent 'subagent-99' not found"

    # Success with running guidance
    res = tool.execute(action: "status", conversation_id: "subagent-1", timeout: 2)
    assert_kind_of String, res
    assert_includes res, "\"id\": \"subagent-1\""
    assert_includes res, "\"guidance\":"
  end

  def test_manage_subagents_wait_action
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    # Empty wait results
    res_empty = tool.execute(action: "wait", conversation_ids: ["subagent-10"])
    assert_includes res_empty.to_s, "No active subagents to wait for."
    assert_includes res_empty.to_s, "Unknown id(s): subagent-10"

    # Successful wait
    sup.wait_for_result = [
      { id: "subagent-1", role: "Researcher", type: "research", state: :completed, max_steps: 10, result: "Summary ok" }
    ]
    res = tool.execute(action: "wait", conversation_id: "subagent-1")
    assert_includes res.to_s, "Subagents wait finished (1 tracked):"
    assert_includes res.to_s, "[subagent-1] 'Researcher' (research) - COMPLETED"
    assert_includes res.to_s, "Result: Summary ok"
  end

  def test_manage_subagents_wait_action_truncates_long_result
    sup = DummySupervisor.new
    long_res = "x" * 2000
    sup.wait_for_result = [
      { id: "subagent-1", role: "Researcher", type: "research", state: :completed, max_steps: 10, result: long_res, transcript: "rubik://storage/t.jsonl" }
    ]
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "wait", conversation_id: "subagent-1")
    assert_includes res.to_s, "[truncated — full result: read_file(path: 'rubik://storage/t.jsonl')]"
  end

  def test_manage_subagents_transcript_action
    sup = DummySupervisor.new
    inst = DummySubagentInstance.new(id: "subagent-1", state: :completed)
    sup.instances = { "subagent-1" => inst }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "transcript", conversation_id: "subagent-1")
    assert_includes res.to_s, "Transcript for subagent-1:"
  end

  def test_manage_subagents_extend_budget_action
    sup = DummySupervisor.new
    inst = DummySubagentInstance.new(id: "subagent-1", state: :budget_exhausted, max_steps: 10)
    sup.instances = { "subagent-1" => inst }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "extend_budget", conversation_id: "subagent-1", steps: 5)
    assert_includes res.to_s, "extended by 5 steps"
    assert_equal 15, inst.max_steps
  end

  def test_manage_subagents_resume_action
    sup = DummySupervisor.new
    inst = DummySubagentInstance.new(id: "subagent-1", state: :paused_error)
    sup.instances = { "subagent-1" => inst }
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    # Resume single
    res = tool.execute(action: "resume", conversation_id: "subagent-1", steps: 5)
    assert_includes res.to_s, "Subagent 'subagent-1' successfully resumed"

    # Resume all
    res_all = tool.execute(action: "resume")
    assert_includes res_all.to_s, "Resumed subagent(s): subagent-1"
  end

  def test_manage_subagents_redeploy_action
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "redeploy", conversation_id: "subagent-1", prompt: "New task")
    assert_includes res.to_s, "Redeployed subagent 'subagent-1' with a new task"
  end

  def test_manage_subagents_reap_action
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "reap")
    assert_includes res.to_s, "Reaped 1 finished subagent(s): subagent-1"
  end

  def test_manage_subagents_kill_and_kill_all_actions
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res_kill = tool.execute(action: "kill", conversation_ids: ["subagent-1", "subagent-2"])
    assert_includes res_kill.to_s, "Killed subagent(s): subagent-1, subagent-2"
    assert_equal ["subagent-1", "subagent-2"], sup.killed_ids

    res_kill_all = tool.execute(action: "kill_all")
    assert_includes res_kill_all.to_s, "All active subagents have been terminated"
  end

  def test_manage_subagents_unknown_action
    sup = DummySupervisor.new
    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: sup)

    res = tool.execute(action: "invalid_action")
    assert res.error?
    assert_includes res.to_s, "Unknown manage_subagents action: 'invalid_action'"
  end

  # =========================================================================
  # 4. DefineSubagentTool
  # =========================================================================

  def test_define_subagent_declaration
    tool = Rubik::Tools::DefineSubagentTool.new
    assert_equal "define_subagent", tool.name
    assert_equal :execute, tool.risk
    assert tool.declaration.subagent_spawn
    assert_includes tool.aliases, "register_subagent_type"
    assert_includes tool.aliases, "create_subagent_type"
  end

  def test_define_subagent_missing_supervisor
    tool = Rubik::Tools::DefineSubagentTool.new
    res = tool.execute(name: "custom", description: "desc", system_prompt: "prompt")
    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_define_subagent_missing_required_params
    sup = DummySupervisor.new
    tool = Rubik::Tools::DefineSubagentTool.new(supervisor: sup)

    res = tool.execute(name: "custom", description: "")
    assert res.error?
    assert_includes res.to_s, "Parameters 'name', 'description', and 'system_prompt' are required"
  end

  def test_define_subagent_successful_archetype_registration
    sup = DummySupervisor.new
    tool = Rubik::Tools::DefineSubagentTool.new(supervisor: sup)

    res = tool.execute(
      name: "security_auditor",
      description: "Audits security risks in code",
      system_prompt: "You are a security auditor.",
      enable_write_tools: true,
      enable_subagent_tools: false
    )

    assert_kind_of String, res
    assert_includes res, "Subagent archetype 'security_auditor' successfully defined"

    defined = sup.type_registry.defined_types.first
    assert_equal "security_auditor", defined.name
    assert_equal "Audits security risks in code", defined.description
    assert_equal "You are a security auditor.", defined.system_prompt
    assert defined.enable_write_tools
    refute defined.enable_subagent_tools
  end
end
