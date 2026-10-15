# frozen_string_literal: true

require_relative "../test_helper"

class TestSkillsManager < Minitest::Test
  def setup
    @project = Dir.mktmpdir("rubik_mgr_project")
    @home = Dir.mktmpdir("rubik_mgr_home")
    @config = Rubik::Config.new(root_dir: @project, home_dir: @home)
    write_skill("alpha", description: "Alpha skill")
  end

  def teardown
    FileUtils.remove_entry(@project)
    FileUtils.remove_entry(@home)
  end

  def write_skill(name, description: "d", body: "\nBody text\n", extra_frontmatter: "")
    write_skill_md(File.join(@project, ".rubik", "skills"), name,
                   description: description, body: body, extra_frontmatter: extra_frontmatter)
  end

  def write_into(skills_root, name)
    write_skill_md(skills_root, name)
  end

  def manager(runtime_context: nil)
    Rubik::Skills::Manager.new(config: @config, root_dir: @project, home_dir: @home, runtime_context: runtime_context)
  end

  def test_prompt_index_carries_name_description_scope
    write_skill("zulu")
    index = manager.prompt_index
    assert_equal(["alpha", "zulu"], index.map { |s| s[:name] })
    assert_equal "Alpha skill", index.first[:description]
    assert_equal :project, index.first[:scope]
  end

  def test_enabled_false_empties_index_and_blocks_find
    @config.set("skills.enabled", false, persist: false)
    mgr = manager
    assert_empty mgr.prompt_index
    assert_empty mgr.all
    assert_nil mgr.find("alpha")
  end

  def test_disabled_manager_hides_skills_from_find
    @config.set("skills.enabled", false, persist: false)
    mgr = manager
    assert_nil mgr.find("alpha")
    assert_equal 0, mgr.status_summary[:total]
    assert mgr.status_summary.key?(:enabled)
  end

  def test_body_returns_markdown_without_frontmatter
    assert_equal "Body text\n", manager.body("alpha")
  end

  def test_body_truncates_head_only_with_read_file_pointer
    write_skill("big", body: "\n#{'line
' * 900}")
    @config.set("skills.max_body_chars", 300, persist: false)
    body = manager.body("big")
    pointer = "Load the omitted tail with read_file: #{File.join(@project, '.rubik', 'skills', 'big', 'SKILL.md')}\n"
    assert_operator body.delete_suffix(pointer).bytesize, :<=, 400
    assert_includes body, "Truncated"
    assert_includes body, "read_file"
    assert_includes body, File.join(@project, ".rubik", "skills", "big", "SKILL.md")
  end

  def test_body_respects_the_line_budget_not_just_chars
    # ~2800 bytes but 400 lines: passes the char cap, must still be capped by
    # the residual line budget (StepExecutor truncates on EITHER axis).
    write_skill("bullets", body: "\n#{'- item
' * 400}")
    body = manager.body("bullets")
    assert_includes body, "- item", "head of the instructions must survive"
    assert_operator body.lines.size, :<=, 300, "must stay under tools.max_output_lines"
    assert_includes body, "read_file", "truncated body must carry the recovery pointer"
    # The full tool output (header + body + pointer) must fit the envelope:
    tool = Rubik::Tools::SkillTool.new(manager).execute("name" => "bullets")
    assert_operator tool.lines.size, :<=, 300
  end

  def test_disabled_names_exclude_skills
    write_skill("beta")
    @config.set("skills.disabled", ["beta"], persist: false)
    assert_equal ["alpha"], manager.all.map(&:name)
    issue = manager.issues.find { |i| i.field == :disabled }
    assert issue, "excluded skill must be reported as an issue"
    assert_predicate issue, :warning?, "an intentional config exclusion is a note, not an error"
  end

  def test_validation_warnings_do_not_inflate_the_skipped_count
    write_skill("warny", extra_frontmatter: "mystery-key: true\n")
    mgr = manager
    assert_includes mgr.all.map(&:name), "warny", "a warning must not reject the skill"
    summary = mgr.status_summary
    assert_equal 0, summary[:skipped]
    assert_equal 1, summary[:notes]
  end

  def test_extra_paths_are_scanned
    extra_dir = File.join(@home, "more-skills", "gamma")
    FileUtils.mkdir_p(extra_dir)
    File.write(File.join(extra_dir, "SKILL.md"), "---\nname: gamma\ndescription: g\n---\n")
    @config.set("skills.paths", [File.join(@home, "more-skills")], persist: false)
    assert_includes manager.all.map(&:name), "gamma"
  end

  def test_reload_picks_up_newly_written_skills
    mgr = manager
    assert_equal ["alpha"], mgr.all.map(&:name)
    write_skill("late")
    mgr.reload!
    assert_equal ["alpha", "late"], mgr.all.map(&:name)
  end

  def test_epoch_registers_and_unregisters_the_skill_tool
    runtime_context = Rubik::Runtime::Context.new
    tool_registry = Rubik::Tools::Registry.new
    mgr = manager(runtime_context: runtime_context)

    mgr.open_epoch!(tool_registry)
    assert_predicate mgr, :epoch_open?
    assert_equal 1, tool_registry.list.count { |t| t.name == "skill" }, "exactly one registration"
    assert_equal :builtin, tool_registry.origin("skill")

    mgr.close_epoch!
    refute_predicate mgr, :epoch_open?
    assert_nil tool_registry.get("skill"), "closing the epoch must unregister the tool"

    # Zero-restart invariant (AGENTS.md §6): repeated open/close cycles
    # leave the parent context exactly as they found it — the runtime
    # prunes the closed epoch's cascade inverse (no per-cycle growth).
    assert_equal 0, runtime_context.disposable_count
    100.times do
      mgr.open_epoch!(tool_registry)
      mgr.close_epoch!
      assert_equal 0, runtime_context.disposable_count
    end
    assert_nil tool_registry.get("skill")
  end

  def test_open_epoch_is_noop_when_disabled
    @config.set("skills.enabled", false, persist: false)
    tool_registry = Rubik::Tools::Registry.new
    mgr = manager
    mgr.open_epoch!(tool_registry)
    assert_nil tool_registry.get("skill")
    refute_predicate mgr, :epoch_open?
  end

  def test_apply_config_transitions_epoch_on_enabled_flip
    tool_registry = Rubik::Tools::Registry.new
    mgr = manager
    mgr.open_epoch!(tool_registry)
    assert tool_registry.get("skill")

    @config.set("skills.enabled", false, persist: false)
    mgr.apply_config!(tool_registry: tool_registry)
    assert_nil tool_registry.get("skill"), "disable must close the epoch"
    assert_empty mgr.prompt_index

    @config.set("skills.enabled", true, persist: false)
    mgr.apply_config!(tool_registry: tool_registry)
    refute_nil tool_registry.get("skill"), "re-enable must reopen the epoch"
    assert_includes mgr.prompt_index.map { |s| s[:name] }, "alpha"
  end

  def test_apply_config_picks_up_new_extra_paths_live
    tool_registry = Rubik::Tools::Registry.new
    mgr = manager
    mgr.open_epoch!(tool_registry)
    refute_includes mgr.all.map(&:name), "late"

    extra_dir = File.join(@home, "late-skills")
    write_into(extra_dir, "late")
    @config.set("skills.paths", [extra_dir], persist: false)
    mgr.apply_config!(tool_registry: tool_registry)
    assert_includes mgr.all.map(&:name), "late", "skills.paths changes must apply without a restart"
    assert mgr.epoch_open?, "enabled-preserving changes must not close the epoch"
  end

  def test_root_context_disposal_disposes_epoch_child
    runtime_manager = Rubik::Runtime::Manager.new
    tool_registry = Rubik::Tools::Registry.new
    mgr = Rubik::Skills::Manager.new(config: @config, root_dir: @project, home_dir: @home,
                                     runtime_context: runtime_manager.context)
    mgr.open_epoch!(tool_registry)
    refute_nil tool_registry.get("skill")

    runtime_manager.dispose!
    assert_nil tool_registry.get("skill"), "root context disposal must cascade into the epoch"
  end
end
