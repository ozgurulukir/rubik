# frozen_string_literal: true

require_relative "../test_helper"

class TestSkillTool < Minitest::Test
  def setup
    @project = Dir.mktmpdir("rubik_tool_project")
    @home = Dir.mktmpdir("rubik_tool_home")
    @config = Rubik::Config.new(root_dir: @project, home_dir: @home)
    write_skill("alpha", description: "Alpha skill", body: "\nDo the alpha thing\n")
  end

  def teardown
    FileUtils.remove_entry(@project)
    FileUtils.remove_entry(@home)
  end

  def write_skill(name, description: "d", body: "\nBody\n")
    write_skill_md(File.join(@project, ".rubik", "skills"), name,
                   description: description, body: body)
  end

  def manager
    @manager ||= Rubik::Skills::Manager.new(config: @config, root_dir: @project, home_dir: @home)
  end

  def tool
    Rubik::Tools::SkillTool.new(manager)
  end

  def test_schema_shape_and_read_risk
    assert_equal "skill", tool.name
    assert_equal :read, tool.risk
    assert tool.description.include?("<skills>")
    assert_equal ["name"], tool.params_schema[:required]
  end

  def test_reQUIRES_declares_skill_manager_coeffect
    assert_equal [Rubik::Coeffects::SKILL_MANAGER], Rubik::Tools::SkillTool::REQUIRES
  end

  def test_happy_path_returns_header_and_body
    res = tool.execute("name" => "alpha")
    refute res.error?
    assert_includes res, "Skill 'alpha' (scope: project"
    assert_includes res, "directory: #{File.join(@project, '.rubik', 'skills', 'alpha')}"
    assert_includes res, "Do the alpha thing"
    refute_includes res, "name: alpha", "frontmatter must not leak into the body"
  end

  def test_missing_and_unknown_names_error_with_available_list
    err = tool.execute({})
    assert_predicate err, :error?
    assert_includes err, "`name` is required"

    err2 = tool.execute("name" => "nope")
    assert_predicate err2, :error?
    assert_includes err2, "unknown skill 'nope'"
    assert_includes err2, "alpha"
  end

  def test_disabled_manager_reports_config_state
    @config.set("skills.enabled", false, persist: false)
    err = tool.execute("name" => "alpha")
    assert_predicate err, :error?
    assert_includes err, "skills.enabled = false"
  end

  def test_unavailable_manager_errors_gracefully
    err = Rubik::Tools::SkillTool.new(nil).execute("name" => "alpha")
    assert_predicate err, :error?
    assert_includes err, "not available"
  end

  def test_coeffect_resolution_through_runtime_context
    runtime = Rubik::Runtime::Manager.new
    ctxless_tool = Rubik::Tools::SkillTool.new(nil, runtime_context: runtime.context)
    assert_includes ctxless_tool.execute("name" => "alpha"), "not available"

    runtime.provide(Rubik::Coeffects::SKILL_MANAGER, manager)
    res = Rubik::Tools::SkillTool.new(nil, runtime_context: runtime.context).execute("name" => "alpha")
    refute_predicate res, :error?, "tool must resolve the manager through the coeffect chain"
  end

  def test_gating_hides_tool_until_coeffect_provided
    runtime = Rubik::Runtime::Manager.new
    registry = Rubik::Tools::Registry.new(coeffect_ctx: runtime.context)
    registry.register(Rubik::Tools::SkillTool.new(nil, runtime_context: runtime.context))

    refute_includes registry.schemas.map { |s| s[:name] }, "skill", "PENDING until skill_manager provided"

    runtime.provide(Rubik::Coeffects::SKILL_MANAGER, manager)
    assert_includes registry.schemas.map { |s| s[:name] }, "skill", "reactivates on provide"
  end

  def test_body_cap_keeps_output_below_step_executor_limit
    write_skill("big", body: "\n" + ("content line\n" * 400))
    @config.set("skills.max_body_chars", 500, persist: false)
    res = tool.execute("name" => "big")
    refute_predicate res, :error?
    assert_operator res.bytesize, :<=, 1200, "head-only pre-truncation must stay well under tools.max_output_chars"
    assert_includes res, "read_file", "truncated body must carry the recovery pointer"
  end
end
