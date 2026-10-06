# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class TestSkillsPromptAndCommand < Minitest::Test
  def setup
    @project = Dir.mktmpdir("rubik_pc_project")
    @home = Dir.mktmpdir("rubik_pc_home")
    @config = Rubik::Config.new(root_dir: @project, home_dir: @home)
    write_skill_md(File.join(@project, ".rubik", "skills"), "commit-helper",
                   description: "Creates <commits> & tags. Use when committing.",
                   body: "\n# Commit Helper\nStep 1\n")
    @out = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @out, root_dir: @project)
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@project)
    FileUtils.remove_entry(@home)
  end

  # --- Prompt section (level-1 disclosure) ---

  def test_build_skills_xml_lists_name_scope_description
    xml = Rubik::Prompt::ContextBuilder.build_skills_xml(
      [{ name: "commit-helper", description: "Creates commits", scope: :project }]
    )
    assert_includes xml, '<skills count="1">'
    assert_includes xml, 'name="commit-helper"'
    assert_includes xml, 'scope="project"'
    assert_includes xml, "Creates commits"
    assert_includes xml, "`skill` tool"
  end

  def test_build_skills_xml_escapes_markup_in_metadata
    xml = Rubik::Prompt::ContextBuilder.build_skills_xml(
      [{ name: "x&y", description: "Creates <commits> & \"tags\"", scope: :user }]
    )
    assert_includes xml, "name=\"x&amp;y\""
    assert_includes xml, "&lt;commits&gt; &amp;"
    refute_includes xml, "<commits>"
  end

  def test_build_skills_xml_empty_and_nil_are_suppressed
    assert_empty Rubik::Prompt::ContextBuilder.build_skills_xml(nil)
    assert_empty Rubik::Prompt::ContextBuilder.build_skills_xml([])
  end

  def test_system_prompt_carries_skills_section_via_services_view
    index = @shell.skill_manager.prompt_index
    services = Rubik::Prompt::Services.from_shell(@shell, root_dir: @project, skills_index: index)
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    assert_includes prompt, "<skills count=\"1\">"
    assert_includes prompt, "commit-helper"
    assert_includes prompt, "Creates &lt;commits&gt; &amp; tags."
  end

  def test_system_prompt_without_skills_slot_stays_unchanged
    services = Rubik::Prompt::Services.from_shell(@shell, root_dir: @project)
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    refute_includes prompt, "<skills"
  end

  def test_disabled_skills_drop_out_of_the_prompt
    @config.set("skills.enabled", false, persist: false)
    @shell.skill_manager.apply_config!(tool_registry: @shell.tool_registry)
    services = Rubik::Prompt::Services.from_shell(
      @shell, root_dir: @project, skills_index: @shell.skill_manager.prompt_index
    )
    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(mode: :default, services: services)
    refute_includes prompt, "<skills"
  end

  # --- Boot wiring ---

  def test_manager_provided_as_coeffect_and_tool_registered
    mgr = Rubik::Coeffects.get(@shell.runtime_manager.context, Rubik::Coeffects::SKILL_MANAGER)
    assert_same @shell.skill_manager, mgr
    assert_equal mgr.object_id, @shell.skill_manager.object_id

    assert @shell.tool_registry.get("skill"), "warm_up! must open the tool epoch"
    assert_includes @shell.tool_registry.schemas.map { |s| s[:name] }, "skill"
  end

  def test_skill_command_registered_for_both_audiences
    assert_equal :both, @shell.commands["skill"][:audience]
    assert_equal :human, @shell.commands["skills"][:audience]
  end

  # --- REPL command surface ---

  def test_skill_list_reports_active_skills
    @shell.execute_input("!skill list")
    assert_includes @out.string, "commit-helper"
    assert_includes @out.string, "[project]"
    assert_includes @out.string, "1 active"
  end

  def test_skill_list_separates_skips_from_notes
    write_skill_md(File.join(@project, ".rubik", "skills"), "warny",
                   extra_frontmatter: "mystery-key: true\n")
    @shell.execute_input("!skill reload")
    assert_includes @out.string, "2 active"
    assert_includes @out.string, "0 skipped, 1 notes"
    assert_includes @out.string, "unknown frontmatter key ignored"
  end

  def test_skill_show_prints_raw_skill_md
    @shell.execute_input("!skill show commit-helper")
    assert_includes @out.string, "name: commit-helper"
    assert_includes @out.string, "# Commit Helper"
  end

  def test_skill_info_prints_metadata_and_allowed_tools
    write_skill_md(File.join(@project, ".rubik", "skills"), "commit-helper",
                   description: "Creates commits.", body: "\nBody\n",
                   extra_frontmatter: "license: MIT\nallowed-tools: \"run_command read_file\"\nmetadata:\n  author: rubik\n")
    @shell.execute_input("!skill reload") # the boot snapshot predates the rewrite
    @shell.execute_input("!skill info commit-helper")
    assert_includes @out.string, "run_command read_file (advisory, not enforced)"
    assert_includes @out.string, "author=rubik"
    assert_includes @out.string, "MIT"
  end

  def test_skill_reload_rescans_and_reports
    write_skill_md(File.join(@project, ".rubik", "skills"), "late", description: "l", body: "")
    @shell.execute_input("!skill reload")
    assert_includes @out.string, "2 active"
    assert_includes @shell.skill_manager.all.map(&:name), "late"
  end

  def test_skill_unknown_subcommand_and_missing_skill
    @shell.execute_input("!skill frobnicate")
    assert_includes @out.string, "Unknown subcommand"
    @shell.execute_input("!skill show ghost")
    assert_includes @out.string, "Unknown skill 'ghost'"
  end

  # --- Compaction: a loaded skill body survives intermediate-result pruning ---

  def test_compactor_preserves_skill_tool_results
    body = "skill body " * 400
    history = [
      { role: "user", content: "task" },
      { role: "assistant", content: "calling skill" },
      { role: "tool", tool_call_id: "1", tool_name: "skill", status: "ok", content: body },
      { role: "tool", tool_call_id: "2", tool_name: "run_command", status: "ok", content: "x" * 3000 },
      { role: "assistant", content: "done" }
    ]
    pruned = Rubik::Prompt::ContextCompactor.prune_intermediate_tool_results(
      history, preserve_first_n: 1, preserve_last_n: 1, max_chars: 100
    )
    assert_equal body, pruned[2][:content], "skill tool result must be exempt from pruning"
    assert_operator pruned[3][:content].length, :<, 3000, "other tool results still get pruned"
  end
end
