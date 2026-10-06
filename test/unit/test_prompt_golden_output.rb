# frozen_string_literal: true

require_relative "../test_helper"

# Prompt policy seam (architecture review 2026-10-01, candidate 2):
# golden fixtures pin the assembled system prompt BYTE-FOR-BYTE, pinned
# BEFORE the doctrine/services extraction so every later phase proves
# byte identity by construction (same discipline as the Plan 87 E-2
# chunk-assembler goldens). Doctrine wording edits belong in
# lib/rubik/prompt/doctrine.rb / tool_teachings.rb — never here.
#
# After a DELIBERATE wording change regenerate the fixtures:
#
#   REGEN=1 bundle exec ruby -Ilib -Itest test/unit/test_prompt_golden_output.rb
#
# Determinism contract: every service input is fixed by construction
# (real Buffer::Manager + Context::Index over a 2-file tmpdir, stub LSP
# manager, builtin TypeRegistry) and the only permitted normalisation is
# the tmpdir path → <ROOT> and its basename → <PROJECT>. The environment
# line is pinned on a stubbed platform (os_family :linux + sandbox.shell
# "bash") so fixtures stay machine-independent; the auto-probing path is
# ShellResolver's own contract, covered in its suite.
class TestPromptGoldenOutput < Minitest::Test
  FIXTURE_DIR = File.expand_path("../fixtures/prompt_golden", __dir__)

  TOOL_SCHEMAS = [
    { "name" => "list_files", "description" => "List files in a directory", "parameters" => { "type" => "object" } },
    { "name" => "read_file", "description" => "Read a file from disk", "parameters" => { "type" => "object" } }
  ].freeze

  def setup
    @root = Dir.mktmpdir("rubik_golden")
    File.write(File.join(@root, "AGENTS.md"), "# Golden Protocol\n- Invariant Omega LIFO")
    FileUtils.mkdir_p(File.join(@root, "lib"))
    File.write(File.join(@root, "lib", "x.rb"), "puts 1\n")

    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @root)
    @buffer_manager.write("dirty_file.rb", "puts 123")
    @snapshot_store = Rubik::Buffer::SnapshotStore.new
    @context_index = Rubik::Context::Index.new(root_dir: @root)
    @context_index.full_scan
    @type_registry = Rubik::Orchestrator::Subagent::TypeRegistry.new
  end

  def teardown
    remove_temp_dir(@root)
  end

  def test_default_prompt_matches_pinned_fixture_byte_for_byte
    assert_pinned "default_json_tools.txt", normalize(rendered_prompt(mode: :default, native_tools: false))
  end

  def test_goal_mode_prompt_matches_pinned_fixture_byte_for_byte
    assert_pinned "goal_native_tools.txt", normalize(rendered_prompt(mode: :goal, native_tools: true))
  end

  def test_plan_mode_prompt_matches_pinned_fixture_and_publishes_no_toolbelt
    rendered = normalize(rendered_prompt(mode: :plan, native_tools: true))
    assert_pinned "plan_native_tools.txt", rendered
    refute_includes rendered, "Available tools", "plan mode is text-only — no toolbelt may be published"
  end

  def test_native_tools_variant_lists_names_without_schema_dump
    rendered = normalize(rendered_prompt(mode: :default, native_tools: true))
    assert_pinned "default_native_tools.txt", rendered
    assert_includes rendered, "Available tools: list_files, read_file"
    refute_includes rendered, '"parameters"', "native mode lists names only; the JSON dump is the fallback variant"
  end

  def test_system_context_section_order_is_stable
    rendered = normalize(rendered_system_context)
    assert_pinned "system_context_full.txt", rendered

    # Budget sections are anchored on their attribute form: rule 6's prose
    # also mentions `<output_budget>` inside the operational rules.
    tags = {
      "operational_rules" => "<operational_rules>", "environment" => "<environment ",
      "protocol" => "<protocol ", "workspace_status" => "<workspace_status>",
      "buffer_status" => "<buffer_status ", "lsp_diagnostics" => "<lsp_diagnostics ",
      "context_budget" => "<context_budget limit=", "output_budget" => "<output_budget limit=",
      "custom_commands" => "<custom_commands>", "skills" => "<skills ",
      "subagents" => "<subagents ", "extra_context" => "<extra_context>"
    }
    positions = tags.values.map { |needle| rendered.index(needle) }
    assert positions.all?, "every pinned section must be present in the golden system context"
    assert_equal positions, positions.sort, "system-context section order must stay stable"
  end

  def test_user_task_wrapper_fixture_pins_the_compactor_contract
    # ContextCompactor#goal_message? pins these exact bytes; never change
    # format_user_task without updating the compactor in the same breath.
    assert_pinned "user_task.txt", Rubik::Prompt::ContextBuilder.format_user_task("Ship the prompt golden fixtures")
  end

  def test_fixture_regeneration_is_idempotent
    first = normalize(rendered_prompt(mode: :default, native_tools: false))
    second = normalize(rendered_prompt(mode: :default, native_tools: false))
    assert_equal first, second, "two renders over identical inputs must be byte-identical"
  end

  private

  def rendered_prompt(mode:, native_tools:)
    Rubik::Platform.stub(:os_family, :linux) do
      Rubik::Prompt::ContextBuilder.build_system_prompt(
        mode: mode, tool_schemas: TOOL_SCHEMAS, native_tools: native_tools, services: golden_services
      )
    end
  end

  def rendered_system_context
    Rubik::Platform.stub(:os_family, :linux) do
      Rubik::Prompt::ContextBuilder.build_system_context(services: golden_services)
    end
  end

  def golden_services
    Rubik::Prompt::Services.new(
      config: { "sandbox.shell" => "bash" },
      commands: { "db_seed" => { description: "Seed the test database", custom: true } },
      buffer_manager: @buffer_manager,
      snapshot_store: @snapshot_store,
      context_index: @context_index,
      lsp_manager: golden_lsp_manager,
      context_limit: 32_768,
      max_output_tokens: 16_384,
      root_dir: @root,
      extra_context: "note",
      skills_index: [{ name: "goldens", description: "Regenerate prompt golden fixtures", scope: "project" }],
      type_registry: @type_registry
    )
  end

  # Minimal deterministic LSP surface: one running server, one error
  # diagnostic — exercises the non-clean branch of build_lsp_xml.
  def golden_lsp_manager
    Class.new do
      define_method(:enabled?) { true }
      define_method(:running?) { true }
      define_method(:servers) { [] }
      define_method(:status_summary) { { servers: { "ruby-lsp" => { running: true } }, running_count: 1, total_diagnostics: 1 } }
      define_method(:all_diagnostics) do
        { "lib/x.rb" => [{ "severity" => 1, "range" => { "start" => { "line" => 0 } }, "message" => "undefined variable x" }] }
      end
    end.new
  end

  # The ONLY permitted transformation: tmpdir path → <ROOT>, basename →
  # <PROJECT> (project_name / working_directory embed them).
  def normalize(rendered)
    rendered.gsub(@root, "<ROOT>").gsub(File.basename(@root), "<PROJECT>")
  end

  # Byte comparison in a single encoding: binread tags content ASCII-8BIT
  # while rendered prompts are UTF-8 (⚠️/• bytes) — == across those is false.
  def assert_pinned(name, actual)
    path = File.join(FIXTURE_DIR, name)
    if ENV["REGEN"]
      FileUtils.mkdir_p(FIXTURE_DIR)
      File.binwrite(path, actual)
      assert_equal actual.b, File.binread(path), "fixture write must round-trip for #{name}"
    else
      assert_equal File.binread(path), actual.b,
                   "rendered prompt drifted from fixture #{name}. Doctrine wording edits belong in " \
                   "lib/rubik/prompt/doctrine.rb (or tool_teachings.rb); after a DELIBERATE wording " \
                   "change regenerate with REGEN=1 (see this file's header)."
    end
  end
end
