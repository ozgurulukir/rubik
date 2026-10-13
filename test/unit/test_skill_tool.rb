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

  def test_requires_declares_skill_manager_coeffect
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

  def test_happy_path_with_symbol_args
    res = tool.execute(name: "alpha")
    refute res.error?
    assert_includes res, "Skill 'alpha' (scope: project"
    assert_includes res, "Do the alpha thing"
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

  def test_empty_skills_list_reports_none_available
    empty_project = Dir.mktmpdir("rubik_empty_project")
    empty_config = Rubik::Config.new(root_dir: empty_project, home_dir: @home)
    empty_mgr = Rubik::Skills::Manager.new(config: empty_config, root_dir: empty_project, home_dir: @home)
    empty_tool = Rubik::Tools::SkillTool.new(empty_mgr)

    err = empty_tool.execute({})
    assert_predicate err, :error?
    assert_includes err, "Available skills: none."

    err2 = empty_tool.execute("name" => "missing")
    assert_predicate err2, :error?
    assert_includes err2, "unknown skill 'missing'. Available skills: none."
  ensure
    FileUtils.remove_entry(empty_project) if empty_project && File.exist?(empty_project)
  end

  def test_unreadable_or_nil_body_returns_error
    mock_skill = Rubik::Skills::Skill.new(name: "corrupt", root: "/tmp/corrupt")
    mock_mgr = Minitest::Mock.new
    mock_mgr.expect(:enabled?, true)
    mock_mgr.expect(:all, [mock_skill])
    mock_mgr.expect(:find, mock_skill, ["corrupt"])
    mock_mgr.expect(:body, nil, ["corrupt"])

    mock_tool = Rubik::Tools::SkillTool.new(mock_mgr)
    err = mock_tool.execute("name" => "corrupt")

    assert_predicate err, :error?
    assert_includes err, "Error: SKILL.md of 'corrupt' could not be read (/tmp/corrupt/SKILL.md)."
    mock_mgr.verify
  end

  def test_mock_skill_manager_execution
    mock_skill = Rubik::Skills::Skill.new(
      name: "mock_skill",
      description: "A mock skill",
      scope: :project,
      root: "/tmp/mock_skill"
    )
    mock_mgr = Minitest::Mock.new
    mock_mgr.expect(:enabled?, true)
    mock_mgr.expect(:all, [mock_skill])
    mock_mgr.expect(:find, mock_skill, ["mock_skill"])
    mock_mgr.expect(:body, "Mock instructions body", ["mock_skill"])

    mock_tool = Rubik::Tools::SkillTool.new(mock_mgr)
    res = mock_tool.execute("name" => "mock_skill")

    refute_predicate res, :error?
    assert_includes res, "Skill 'mock_skill' (scope: project, directory: /tmp/mock_skill)"
    assert_includes res, "Mock instructions body"
    mock_mgr.verify
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
    write_skill("big", body: "\n#{'content line
' * 400}")
    @config.set("skills.max_body_chars", 500, persist: false)
    res = tool.execute("name" => "big")
    refute_predicate res, :error?
    assert_operator res.bytesize, :<=, 1200, "head-only pre-truncation must stay well under tools.max_output_chars"
    assert_includes res, "read_file", "truncated body must carry the recovery pointer"
  end
end
