# frozen_string_literal: true

require_relative "../test_helper"

# Declaration + Catalog invariants (architecture review 2026-10-01,
# candidate 1). The parity literals below are INDEPENDENT copies of the
# hand-lists that predate the Catalog — they pin the projection to the
# behavior that shipped, so flipping consumers (type_registry, maestro_gate)
# onto Catalog cannot silently change a policy set.
class TestToolDeclarationCatalog < Minitest::Test
  # type_registry.rb READ_ONLY_TOOLS (research allowlist), 2026-10-01.
  # Projections are SORTED sets — membership parity, not list order.
  RESEARCH_PARITY = [
    "ask_question", "find_references", "get_outline", "get_symbol", "grep_search",
    "list_files", "lsp_definition", "lsp_diagnostics", "lsp_hover", "read_file", "search_symbols"
  ].freeze

  # type_registry.rb CODER_TOOLS; coder gained the execution toolbelt
  # (run_command, manage_task) with the maestro-consistency plan 2026-10-02.
  CODER_PARITY = [
    "apply_buffer", "ask_question", "grep_search", "list_files", "lsp_diagnostics",
    "manage_task", "read_file", "replace_file_content", "run_command", "run_tests",
    "storage", "write_file"
  ].freeze

  # type_registry.rb SUBAGENT_SPAWN_TOOLS + define_custom write-deny, 2026-10-01
  SPAWN_PARITY = ["define_subagent", "invoke_subagent"].freeze
  WRITE_GRANT_PARITY = ["apply_buffer", "replace_file_content", "run_command", "storage", "write_file"].freeze

  # maestro_gate.rb MAESTRO_BLOCKED_TOOLS as it stood before the Catalog
  # flip (2026-10-01)
  MAESTRO_PARITY = ["manage_task", "replace_file_content", "run_command", "run_tests", "write_file"].freeze

  def setup
    @temp_dir = Dir.mktmpdir("rubik_declaration_catalog")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @registry = Rubik::Tools::Registry.build_default(
      buffer_manager: @buffer_manager,
      context_index: Rubik::Context::Index.new(root_dir: @temp_dir),
      ast_graph: Rubik::AST::Graph.new,
      adapter_registry: Rubik::Adapter::Registry.new,
      guard: Rubik::Security::Guard.new,
      sandbox_runner: Rubik::Sandbox::Runner.new(root_dir: @temp_dir),
      root_dir: @temp_dir
    )
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_research_tool_set_derives_from_archetype_declarations
    assert_equal RESEARCH_PARITY, Rubik::Tools::Catalog.research_tools
  end

  def test_coder_tool_set_derives_from_archetype_declarations
    assert_equal CODER_PARITY, Rubik::Tools::Catalog.coder_tools
  end

  def test_spawn_tool_set_and_custom_write_grant_set_derive_from_declarations
    assert_equal SPAWN_PARITY, Rubik::Tools::Catalog.spawn_tools
    assert_equal WRITE_GRANT_PARITY, Rubik::Tools::Catalog.write_grant_tools
  end

  def test_maestro_blocked_set_derives_from_declarations
    assert_equal MAESTRO_PARITY, Rubik::Tools::Catalog.maestro_blocked_tools
    assert Rubik::Tools::Catalog.maestro_blocked?("write_file")
    refute Rubik::Tools::Catalog.maestro_blocked?("apply_buffer")
    refute Rubik::Tools::Catalog.maestro_blocked?("read_file")
  end

  def test_build_default_registers_exactly_the_catalog_tools_in_catalog_order
    assert_equal Rubik::Tools::Catalog.names, @registry.list.map(&:name)
  end

  def test_every_mutating_tool_declares_its_maestro_gate_class_explicitly
    # No silent gate escape: a NEW mutating tool that omits maestro_blocked
    # fails here instead of slipping past the gate unnoticed.
    undeclared = Rubik::Tools::Catalog.declarations
                                      .select { |d| [:write, :execute].include?(d.risk) && d.maestro_blocked.nil? }
                                      .map(&:name)
    assert_empty undeclared,
                 "mutating tools must declare maestro_blocked: true|false explicitly (got nil for: #{undeclared.join(', ')})"
  end

  def test_declaration_aliases_and_names_are_unique_across_the_toolbelt
    all = (Rubik::Tools::Catalog.declarations + Rubik::Tools::Catalog.dynamic_declarations)
          .flat_map { |d| [d.name] + d.aliases }.map(&:downcase)
    duplicates = all.tally.select { |_k, v| v > 1 }.keys
    assert_empty duplicates, "tool names/aliases must be unique registry keys (duplicated: #{duplicates.join(', ')})"
  end

  def test_tool_schema_payload_stays_policy_free
    schemas = @registry.schemas
    assert_equal 35, schemas.size
    schemas.each do |schema|
      assert_equal [:name, :description, :risk, :parameters], schema.keys,
                   "to_h must never leak policy fields (#{schema[:name]} emits #{schema.keys})"
    end
  end

  def test_kwargs_path_still_builds_a_fully_functional_tool
    tool = Rubik::Tools::BaseTool.new(
      name: "custom_probe", description: "dynamic/test-double construction path",
      risk: :write, aliases: ["probe"], archetypes: [:coder], write_grant: true, maestro_blocked: false
    )
    assert_equal "custom_probe", tool.name
    assert_equal ["probe"], tool.aliases
    assert_equal :write, tool.risk
    assert_equal [:coder], tool.archetypes
    assert tool.write_grant?
    refute tool.maestro_blocked?
    assert_equal [:name, :description, :risk, :parameters], tool.to_h.keys
  end

  def test_declaration_validates_its_shape
    assert_raises(ArgumentError) { Rubik::Tools::Declaration.new(name: "Bad-Name", description: "x") }
    assert_raises(ArgumentError) { Rubik::Tools::Declaration.new(name: "ok_name", description: "x", risk: :wild) }
    assert_raises(ArgumentError) { Rubik::Tools::Declaration.new(name: "ok_name", description: "x", archetypes: [:chef]) }
    # Leading digits stay legal: synthesis/overlay normalization keeps them
    # and legacy dynamic tools with such names must keep loading.
    assert_equal "4calc", Rubik::Tools::Declaration.new(name: "4calc", description: "legacy dynamic").name
    d = Rubik::Tools::Declaration.new(name: :symbolic, description: :plain)
    assert_equal "symbolic", d.name
    assert_equal :read, d.risk
    assert d.frozen?
    assert d.aliases.frozen?
    assert d.with(risk: :write).risk == :write
  end
end
