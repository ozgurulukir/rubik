# frozen_string_literal: true

require_relative "../test_helper"

# Candidate 05: the ServiceCatalog guard lock. The catalog is the single
# declaration point for service wiring — these tests pin catalog <-> Parts
# <-> provides <-> Coeffects consistency and the load-bearing construction
# order so the derivation cannot drift silently (candidate-04 directory-scan
# doctrine: the seam is enforced where it is declared).
class TestServiceCatalog < Minitest::Test
  CATALOG = Rubik::REPL::ServiceCatalog

  EXPECTED_MEMBER_NAMES = [
    :config, :event_bus, :extra_roots, :allowed_ext_dirs, :allow_ext_writes,
    :guard, :buffer_manager, :snapshot_store, :cache_store, :ast_graph,
    :context_index, :recorder, :adapter_registry, :llm_registry, :router,
    :runtime_manager, :overlay_storage, :lsp_manager, :mcp_manager,
    :skill_manager, :sandbox_runner, :plugin_manager, :plugin_storage,
    :task_manager, :subagent_supervisor
  ].freeze

  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_member_names_match_the_snapshot_exactly
    assert_equal EXPECTED_MEMBER_NAMES, CATALOG.member_names
  end

  def test_parts_struct_members_derive_from_the_catalog
    assert_equal EXPECTED_MEMBER_NAMES, Rubik::REPL::Composition::Parts.members
  end

  def test_parts_struct_returns_struct_class_with_keyword_init
    struct_class = CATALOG.parts_struct
    assert_kind_of Class, struct_class
    assert_operator struct_class, :<, Struct
    assert_equal EXPECTED_MEMBER_NAMES, struct_class.members

    instance = struct_class.new(config: :dummy_config)
    assert_equal :dummy_config, instance.config
  end

  def test_names_and_provide_keys_are_unique
    names = CATALOG::ENTRIES.map(&:name)
    assert_equal names.uniq, names
    keys = CATALOG.provided.map(&:provide)
    assert_equal keys.uniq, keys
  end

  def test_provide_key_set_is_the_wire_contract
    expected = [
      "config", "events", "guard", "buffer_manager", "snapshot_store",
      "lsp_manager", "mcp_manager", "skill_manager", "sandbox",
      "adapter_registry", "shell", "plugin_manager", "plugin_storage",
      "task_manager", "subagent_supervisor", "router"
    ]
    assert_equal expected.sort, CATALOG.provided.map(&:provide).sort
  end

  def test_short_literal_keys_stay_short
    assert_equal "sandbox", Rubik::Coeffects::SANDBOX_RUNNER
    assert_equal "events", Rubik::Coeffects::EVENTS
  end

  # The load-bearing invariants carried over from the pre-catalog
  # Shell#initialize construction sequence.
  def test_construction_order_is_load_bearing
    order = CATALOG::ENTRIES.each_with_index.to_h { |e, i| [e.name, i] }
    [:buffer_manager, :mcp_manager, :sandbox_runner, :task_manager].each do |consumer|
      assert_operator order.fetch(:guard), :<, order.fetch(consumer),
                      "guard must be constructed before #{consumer}"
    end
    [:mcp_manager, :skill_manager, :task_manager].each do |consumer|
      assert_operator order.fetch(:runtime_manager), :<, order.fetch(consumer),
                      "runtime_manager must be constructed before #{consumer}"
    end
    assert_operator order.fetch(:buffer_manager), :<, order.fetch(:subagent_supervisor),
                    "buffer_manager must be constructed before subagent_supervisor"
  end

  def test_injectable_filters_entries_correctly
    injectables = CATALOG.injectable
    assert injectables.all? { |e| e.is_a?(Rubik::Runtime::ServiceDefinition) }
    assert injectables.all?(&:injectable?)

    names = injectables.map(&:name)
    # Inputs, assign_ivar: false, and non-parts_member entries are excluded
    refute_includes names, :extra_roots
    refute_includes names, :allowed_ext_dirs
    refute_includes names, :allow_ext_writes
    refute_includes names, :plugin_storage
    refute_includes names, :shell

    expected_injectable_names = [
      :config, :event_bus, :guard, :buffer_manager, :snapshot_store,
      :cache_store, :ast_graph, :context_index, :recorder, :adapter_registry,
      :llm_registry, :router, :runtime_manager, :overlay_storage,
      :lsp_manager, :mcp_manager, :skill_manager, :sandbox_runner,
      :plugin_manager, :task_manager, :subagent_supervisor
    ]
    assert_equal expected_injectable_names, names
  end

  def test_reader_names_exclude_the_unreadable
    readers = CATALOG.reader_names
    refute_includes readers, :plugin_manager
    refute_includes readers, :plugin_storage
    refute_includes readers, :extra_roots
    assert_includes readers, :guard
  end

  def test_composition_carries_no_construction
    src = File.read(File.expand_path("../../lib/rubik/repl/composition.rb", __dir__))
    refute_match(/Rubik::[A-Z][\w:]*\.new/, src,
                 "construction belongs in ServiceCatalog builders, not the fold")
  end

  def test_scope_forward_reference_raises_loudly
    scope = CATALOG::Scope.new(root_dir: @temp_dir, overrides: {})
    assert_raises(KeyError) { scope[:never_registered] }
  end

  def test_scope_override_is_visible_before_its_entry_folds
    injected = Object.new
    scope = CATALOG::Scope.new(root_dir: @temp_dir, overrides: { guard: injected })
    assert_same injected, scope[:guard]
  end

  def test_scope_override_for_returns_override_if_present_or_nil
    injected = Object.new
    scope = CATALOG::Scope.new(root_dir: @temp_dir, overrides: { guard: injected })

    assert_same injected, scope.override_for(:guard)
    assert_nil scope.override_for(:buffer_manager)
  end

  def test_fold_builds_every_part_with_shared_guard_identity
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)

    EXPECTED_MEMBER_NAMES.each { |member| refute_nil parts[member], "expected #{member} to be constructed" }
    assert_same parts.guard, parts.task_manager.guard
    assert_same parts.guard, parts.buffer_manager.guard
  end

  # --- Stage 3 locks: derivation of readers, injection and wire rows ---

  def test_shell_exposes_every_catalog_reader
    shell_methods = Rubik::REPL::Shell.public_instance_methods
    CATALOG.reader_names.each do |reader|
      assert_includes shell_methods, reader, "Shell must expose derived reader :#{reader}"
    end
    refute_includes shell_methods, :plugin_manager
    refute_includes shell_methods, :plugin_storage
  end

  def test_shell_attr_lines_do_not_hand_list_catalog_services
    src = File.read(File.expand_path("../../lib/rubik/repl/shell.rb", __dir__))
    hand_lines = src.lines.select { |l| l.match?(/^\s*attr_(reader|accessor)/) && !l.include?("ServiceCatalog") }
    hand_symbols = hand_lines.flat_map { |l| l.scan(/:([a-z_]+)/) }.flatten.map(&:to_sym)
    overlap = hand_symbols & CATALOG.reader_names
    assert overlap.empty?, "catalog readers must derive from ServiceCatalog, not hand-listed: #{overlap.inspect}"
  end

  def test_lifecycle_injection_is_catalog_driven
    # Directory scan (candidate-04 doctrine): the invariant self-maintains
    # as new repl files appear.
    Dir.glob(File.join(File.expand_path("../../lib/rubik/repl", __dir__), "**", "*.rb")).each do |f|
      src = File.read(f)
      refute_match(/@\w+\s*=\s*parts\./, src,
                   "service ivars derive from ServiceCatalog — no hand-typed parts assignments (#{f})")
    end
  end

  def test_shell_publishes_exactly_the_catalog_wire_rows
    require "stringio"
    parts = Rubik::REPL::Composition.build(config: nil, root_dir: @temp_dir)
    shell = Rubik::REPL::Shell.new(output: StringIO.new, parts: parts)
    ctx = shell.runtime_manager.context

    CATALOG.provided.each do |entry|
      expected =
        case entry.provide_from
        when :self  then shell
        when :parts then parts[entry.name]
        else shell.instance_variable_get(:"@#{entry.name}")
        end
      assert_same expected, ctx.get(entry.provide), "wire row #{entry.provide}"
    end
  end

  # --- Stage 4 locks: the Tools::Services triple chain ---

  def test_services_slots_are_catalog_members
    catalog_names = CATALOG::ENTRIES.map(&:name)
    Rubik::Tools::Services::ORDER.each do |slot|
      assert_includes catalog_names, slot, "Services slot :#{slot} must be a catalog member"
    end
  end

  def test_services_unknown_override_raises_naming_valid_slots
    error = assert_raises(ArgumentError) do
      Rubik::Tools::Services.new(overrides: { nonsense: Object.new })
    end
    assert_includes error.message, "nonsense"
    assert_includes error.message, ":guard"
  end

  def test_services_triple_chain_precedence_override_then_coeffect
    ctx = Rubik::Runtime::Context.new
    provided_guard = Rubik::Security::Guard.new
    ctx.provide(Rubik::Coeffects::GUARD, provided_guard)

    override_guard = Rubik::Security::Guard.new
    with_override = Rubik::Tools::Services.new(ctx: ctx, overrides: { guard: override_guard })
    assert_same override_guard, with_override.guard

    ctx_only = Rubik::Tools::Services.new(ctx: ctx, overrides: {})
    assert_same provided_guard, ctx_only.guard
  ensure
    ctx&.dispose
  end

  def test_services_nil_ctx_fresh_defaults_are_fail_closed
    svc = Rubik::Tools::Services.new(root_dir: @temp_dir)

    assert_instance_of Rubik::Security::Guard, svc.guard
    assert_instance_of Rubik::Context::Index, svc.context_index
    assert_instance_of Rubik::Adapter::Registry, svc.adapter_registry
    assert_instance_of Rubik::AST::Graph, svc.ast_graph
    assert_instance_of Rubik::Sandbox::Runner, svc.sandbox_runner
    assert_nil svc.task_manager
    assert_nil svc.subagent_supervisor
  end

  def test_services_sandbox_fresh_chains_onto_the_resolved_guard
    ctx = Rubik::Runtime::Context.new
    provided_guard = Rubik::Security::Guard.new
    ctx.provide(Rubik::Coeffects::GUARD, provided_guard)

    runner = Rubik::Tools::Services.new(ctx: ctx, root_dir: @temp_dir).sandbox_runner
    assert_instance_of Rubik::Sandbox::Runner, runner
    assert_same provided_guard, runner.guard
  ensure
    ctx&.dispose
  end

  def test_build_default_rejects_unknown_service_kwargs
    buffer = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    error = assert_raises(ArgumentError) do
      Rubik::Tools::Registry.build_default(buffer_manager: buffer, root_dir: @temp_dir, frobnicate: 1)
    end
    assert_includes error.message, "frobnicate"
  end

  def test_services_coeffect_keys_mirror_the_catalog_provides
    by_name = CATALOG::ENTRIES.to_h { |e| [e.name, e] }
    Rubik::Tools::Services::ORDER.each do |slot|
      entry = by_name.fetch(slot)
      assert Rubik::Tools::Services::COEFFECTS.key?(slot), "slot :#{slot} missing a COEFFECTS row"
      # ast_graph/context_index enter the context at phase 4 (ASTService /
      # IndexService) under their canonical keys, so their catalog entries
      # carry no wire provide — mirror those against the Coeffects SSOT.
      expected = entry.provide || Rubik::Coeffects.const_get(slot.to_s.upcase)
      assert_equal expected, Rubik::Tools::Services::COEFFECTS.fetch(slot),
                   "Services coeffect key for :#{slot} diverged from the catalog/Coeffects SSOT"
    end
  end

  def test_services_coeffect_tier_returns_the_session_sandbox_runner
    ctx = Rubik::Runtime::Context.new
    session_runner = Rubik::Sandbox::Runner.new(root_dir: @temp_dir)
    ctx.provide(Rubik::Coeffects::SANDBOX_RUNNER, session_runner)

    resolved = Rubik::Tools::Services.new(ctx: ctx, root_dir: @temp_dir).sandbox_runner
    assert_same session_runner, resolved,
                "a broken coeffect tier would silently fall through to a policy-divergent fresh runner"
  ensure
    ctx&.dispose
  end

  def test_shell_registry_gives_runtests_the_session_context_index
    require "stringio"
    shell = Rubik::REPL::Shell.new(output: StringIO.new, config: Rubik::Config.new(root_dir: @temp_dir))
    run_tests = shell.tool_registry.get("run_tests")

    assert_same shell.context_index, run_tests.instance_variable_get(:@context_index),
                "RunTestsTool language detection must see the session's index (raw-kwarg semantics)"
  end
end
