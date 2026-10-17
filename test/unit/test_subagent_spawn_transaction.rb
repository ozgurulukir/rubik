# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

class TestSubagentSpawnTransaction < Minitest::Test
  class TrackingContext < Rubik::Runtime::Context
    attr_reader :created_children

    def initialize(*, **)
      @created_children = []
      super
    end

    def extend
      child = super
      @created_children << child
      child
    end
  end

  def setup
    @ws_root = mint_test_root
    @root_context = TrackingContext.new
    @supervisors = []
  end

  def teardown
    @supervisors.each(&:shutdown_all)
    @root_context.dispose unless @root_context.disposed?
    remove_temp_dir(@ws_root) if @ws_root
  end

  def test_missing_coeffects_fail_before_child_context_or_worker_creation
    provider_calls = Queue.new
    provider = provider_recording_calls(provider_calls)
    supervisor = new_supervisor(provider: provider)
    supervisor.type_registry.define_custom(
      name: "needs_skill_manager", description: "Needs a service", system_prompt: "Use the service.",
      requires: ["skill_manager"], grants: []
    )

    error = assert_raises(Rubik::Orchestrator::Subagent::UnsatisfiedCoeffectsError) do
      supervisor.spawn(role: "Service task", prompt: "Use the required service.", type_name: "needs_skill_manager")
    end

    assert_includes error.message, "skill_manager"
    assert_empty @root_context.created_children
    assert_empty supervisor.instances
    assert provider_calls.empty?, "the provider must not be called before required coeffects are satisfied"
  end

  def test_activation_supplied_coeffects_are_satisfied_before_the_worker_starts
    started = Queue.new
    release = Queue.new
    supervisor = new_supervisor(provider: blocking_first_call_provider(started, release))
    sender_id = Rubik::Coeffects::SUBAGENT_SENDER_ID
    supervisor.type_registry.define_custom(
      name: "needs_sender", description: "Needs its sender identity", system_prompt: "Use the sender identity.",
      requires: [sender_id], grants: []
    )

    instance = supervisor.spawn(role: "Sender-aware task", prompt: "Use your sender identity.",
                                type_name: "needs_sender")
    Timeout.timeout(3) { started.pop }

    assert_equal [sender_id], instance.profile_snapshot.requires
    assert_equal instance.id, Rubik::Coeffects.get(instance.context, sender_id)
  ensure
    release << :continue if release
  end

  def test_active_instance_keeps_its_prompt_grants_and_tool_filter_after_profile_replacement
    started = Queue.new
    release = Queue.new
    supervisor = new_supervisor(provider: blocking_first_call_provider(started, release))
    supervisor.type_registry.define_custom(
      name: "snapshot_probe", description: "Initial profile", system_prompt: "Initial system prompt.", grants: []
    )

    active = supervisor.spawn(role: "Snapshot probe", prompt: "First run", type_name: "snapshot_probe")
    Timeout.timeout(3) { started.pop }
    original_snapshot = active.profile_snapshot
    write_tool = Rubik::Tools::Catalog.write_grant_tools.first
    refute_nil write_tool
    refute original_snapshot.tool_filter.call(write_tool)

    supervisor.type_registry.define_custom(
      name: "snapshot_probe", description: "Updated profile", system_prompt: "Updated system prompt.",
      grants: ["write"], replace: true
    )
    future = supervisor.spawn(role: "Snapshot probe", prompt: "Second run", type_name: "snapshot_probe")

    assert original_snapshot.frozen?
    assert original_snapshot.grants.frozen?
    assert original_snapshot.system_prompt.frozen?
    assert_same original_snapshot, active.profile_snapshot
    assert_equal "Initial system prompt.", active.system_prompt
    assert_equal "Initial system prompt.", original_snapshot.effective_system_prompt
    refute_includes original_snapshot.grants, "write"
    refute original_snapshot.tool_filter.call(write_tool)
    assert_includes future.profile_snapshot.grants, "write"
    assert future.profile_snapshot.tool_filter.call(write_tool)
    assert_equal "Updated system prompt.", future.system_prompt
    assert_operator future.profile_snapshot.revision, :>, original_snapshot.revision
  ensure
    release << :continue if release
  end

  def test_registry_build_failure_disposes_only_the_new_child_context
    root_marker = Object.new
    @root_context.provide("root_marker", root_marker)
    sibling = @root_context.extend
    child_count = @root_context.created_children.length
    failing_supervisor = Class.new(Rubik::Orchestrator::Subagent::Supervisor) do
      private

      def build_scoped_registry(*)
        raise "injected scoped registry failure"
      end
    end
    supervisor = new_supervisor(supervisor_class: failing_supervisor)

    error = assert_raises(RuntimeError) do
      supervisor.spawn(role: "Rollback", prompt: "Fail while building tools")
    end

    assert_includes error.message, "injected scoped registry failure"
    assert_equal child_count + 1, @root_context.created_children.length
    assert @root_context.created_children.last.disposed?
    refute sibling.disposed?
    refute @root_context.disposed?
    assert_same root_marker, @root_context.get("root_marker")
    assert_empty supervisor.instances
    assert_equal 0, supervisor.instance_variable_get(:@counter)
  end

  def test_instance_construction_failure_disposes_the_child_and_returns_the_id
    init = Rubik::Kernel::Init.new
    supervisor = new_supervisor(init: init)

    Rubik::Orchestrator::Subagent::Instance.stub(:new, ->(**_options) { raise "injected instance construction failure" }) do
      error = assert_raises(RuntimeError) do
        supervisor.spawn(role: "Rollback", prompt: "Fail while constructing the instance")
      end
      assert_includes error.message, "injected instance construction failure"
    end

    assert @root_context.created_children.last.disposed?
    assert_nil init.get("subagent-1")
    assert_empty supervisor.instances
    assert_equal 0, supervisor.instance_variable_get(:@counter)
  end

  def test_partial_kernel_registration_is_unregistered_on_spawn_failure
    init = Rubik::Kernel::Init.new
    spy = Object.new
    spy.define_singleton_method(:register) do |unit|
      init.register(unit)
      raise "injected post-registration failure"
    end
    spy.define_singleton_method(:unregister) { |unit| init.unregister(unit) }
    supervisor = new_supervisor(init: spy)

    error = assert_raises(RuntimeError) do
      supervisor.spawn(role: "Rollback", prompt: "Fail after init registration")
    end

    assert_includes error.message, "injected post-registration failure"
    assert_nil init.get("subagent-1")
    assert_empty supervisor.instances
    assert @root_context.created_children.last.disposed?
    assert_equal 0, supervisor.instance_variable_get(:@counter)
  end

  def test_activation_failure_aborts_the_parked_worker_and_rolls_back_instance
    init = Rubik::Kernel::Init.new
    failing_supervisor = Class.new(Rubik::Orchestrator::Subagent::Supervisor) do
      attr_reader :prepared_instance

      def activate_instance!(inst, **kwargs)
        super
        @prepared_instance = inst
        raise "injected failure after worker preparation"
      end
    end
    supervisor = new_supervisor(supervisor_class: failing_supervisor, init: init)

    assert_raises(RuntimeError) do
      supervisor.spawn(role: "Rollback", prompt: "Fail after worker preparation")
    end

    inst = supervisor.prepared_instance
    refute_nil inst
    refute inst.instance_variable_get(:@thread).alive?
    assert inst.context.disposed?
    assert_nil init.get(inst.id)
    assert_empty supervisor.instances
    assert_equal 0, supervisor.instance_variable_get(:@counter)
  end

  def test_release_gate_failure_aborts_worker_and_removes_kernel_unit
    init = Rubik::Kernel::Init.new
    instances = []
    original_new = Rubik::Orchestrator::Subagent::Instance.method(:new)
    factory = lambda do |**options|
      inst = original_new.call(**options)
      instances << inst
      inst.define_singleton_method(:release_start!) { raise "injected start gate failure" }
      inst
    end
    supervisor = new_supervisor(init: init)

    Rubik::Orchestrator::Subagent::Instance.stub(:new, factory) do
      assert_raises(RuntimeError) do
        supervisor.spawn(role: "Rollback", prompt: "Fail before releasing worker")
      end
    end

    inst = instances.fetch(0)
    refute inst.instance_variable_get(:@thread).alive?
    assert inst.context.disposed?
    assert_nil init.get(inst.id)
    assert_empty supervisor.instances
    assert_equal 0, supervisor.instance_variable_get(:@counter)
  end

  def test_reserved_harness_roles_use_their_builtin_profiles_and_do_not_fall_back
    supervisor = new_supervisor
    builtins = supervisor.type_registry.builtins

    { "Vakanüvis Distiller" => "vakanuvis", "Context Pruner" => "pruner" }.each do |role, name|
      builtin = builtins.find { |type| type.name == name }
      instance = supervisor.spawn(role: role, prompt: "Reserved role task", type_name: "research")

      assert_equal name, instance.type_name
      assert_equal builtin.system_prompt, instance.profile_snapshot.system_prompt
      assert_same builtin.tool_filter, instance.profile_snapshot.tool_filter
    end

    children_before_missing = @root_context.created_children.length
    supervisor.type_registry.stub(:builtins, []) do
      assert_raises(Rubik::Orchestrator::Subagent::ReservedProfileError) do
        supervisor.spawn(role: "Context Pruner", prompt: "Do not use a generic fallback", type_name: "research")
      end
    end
    assert_equal children_before_missing, @root_context.created_children.length
  end

  def test_invoke_subagent_reports_a_failed_launch_as_an_error_to_maestro
    supervisor = new_supervisor
    supervisor.type_registry.define_custom(
      name: "needs_skill_manager", description: "Needs a service", system_prompt: "Use the service.",
      requires: ["skill_manager"], grants: []
    )
    tool = Rubik::Tools::InvokeSubagentTool.new(supervisor: supervisor)

    result = tool.execute(type_name: "needs_skill_manager", role: "Service task", prompt: "Use the service.")

    assert result.error?
    assert_includes result.to_s, "FAILED TO START"
    assert_includes result.to_s, "skill_manager"
    assert_empty supervisor.instances
    assert_empty @root_context.created_children
  end

  private

  def new_supervisor(provider: nil, init: nil, supervisor_class: Rubik::Orchestrator::Subagent::Supervisor)
    supervisor = supervisor_class.new(
      root_context: @root_context, root_dir: @ws_root,
      provider: provider || done_provider, init: init
    )
    @supervisors << supervisor
    supervisor
  end

  def done_provider
    response = Struct.new(:content, :tool_calls).new("done", [])
    provider = Object.new
    provider.define_singleton_method(:complete) { |_history, _options = {}| response }
    provider
  end

  def provider_recording_calls(calls)
    response = Struct.new(:content, :tool_calls).new("done", [])
    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, _options = {}|
      calls << true
      response
    end
    provider
  end

  def blocking_first_call_provider(started, release)
    calls = 0
    lock = Mutex.new
    response = Struct.new(:content, :tool_calls).new("done", [])
    provider = Object.new
    provider.define_singleton_method(:complete) do |_history, _options = {}|
      call = lock.synchronize { calls += 1 }
      if call == 1
        started << true
        release.pop
      end
      response
    end
    provider
  end
end
